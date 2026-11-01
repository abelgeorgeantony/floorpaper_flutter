import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/remote_catalog.dart';
import 'downloaded_tile_store.dart';

class RemoteTileException implements Exception {
  final String message;
  const RemoteTileException(this.message);
  @override
  String toString() => message;
}

// Top-level so the background isolate only carries the zip bytes.
Map<String, Uint8List> _unzip(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final files = <String, Uint8List>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final bytes = entry.readBytes();
    if (bytes == null) continue;
    files[entry.name.split('/').last] = bytes;
  }
  return files;
}

Future<Map<String, Uint8List>> _unzipInBackground(Uint8List zipBytes) =>
    Isolate.run(() => _unzip(zipBytes));

/// Outcome of a pack download. [failed] holds human-readable tile names that
/// could not be verified; they are safe to retry.
typedef PackDownloadResult = ({int saved, List<String> failed});

class RemoteTileRepository {
  RemoteTileRepository({
    DownloadedTileStore? store,
    http.Client? client,
  })  : store = store ?? DownloadedTileStore(),
        _client = client ?? http.Client();

  final DownloadedTileStore store;
  final http.Client _client;

  /// Releases the underlying HTTP connection pool. Call when the owning
  /// screen is disposed.
  void dispose() => _client.close();

  // ---------------------------------------------------------------------------
  // Catalogue (with on-disk cache)
  // ---------------------------------------------------------------------------

  Future<RemoteCatalog> fetchCatalog({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await _readCatalogCache();
      if (cached != null) return cached;
    }

    final catalog = await _fetchCatalogNetwork();
    await _writeCatalogCache(catalog);
    return catalog;
  }

  Future<File> _cacheFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/remote_catalog_cache.json');
  }

  Future<RemoteCatalog?> _readCatalogCache() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return null;

      final stat = await file.stat();
      final age = DateTime.now().difference(stat.modified);
      if (age > AppConfig.catalogCacheTtl) return null;

      final decoded = jsonDecode(await file.readAsString());
      return RemoteCatalog.fromJson(decoded as Map<String, dynamic>);
    } catch (_) {
      return null; // corrupt cache is not fatal: just refetch
    }
  }

  Future<void> _writeCatalogCache(RemoteCatalog catalog) async {
    try {
      final file = await _cacheFile();
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(catalog.toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // best-effort: a failed cache write must not break the fetch
    }
  }

  Future<RemoteCatalog> _fetchCatalogNetwork() async {
    try {
      final response = await _client
          .get(Uri.parse(AppConfig.metadataUrl))
          .timeout(AppConfig.catalogTimeout);

      if (response.statusCode != 200) {
        throw RemoteTileException(
            'Could not fetch the tile catalogue (HTTP ${response.statusCode}).');
      }

      final catalog = RemoteCatalog.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );

      if (catalog.schemaVersion > RemoteCatalog.supportedSchema) {
        throw const RemoteTileException(
            'This catalogue needs a newer version of the app.');
      }
      return catalog;
    } on RemoteTileException {
      rethrow;
    } on FormatException {
      throw const RemoteTileException('The tile catalogue is not valid JSON.');
    } on TypeError {
      throw const RemoteTileException(
          'The tile catalogue has an unexpected format.');
    } catch (_) {
      throw const RemoteTileException(
          'Could not reach the tile catalogue. Check your connection.');
    }
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  Future<Uint8List> _download(
    Uri url, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final request = http.Request('GET', url); // follows GitHub redirects
      final response =
          await _client.send(request).timeout(AppConfig.downloadTimeout);

      if (response.statusCode != 200) {
        throw RemoteTileException(
            'Download failed (HTTP ${response.statusCode}).');
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      final builder = BytesBuilder(copy: false);

      await for (final chunk in response.stream) {
        builder.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      return builder.takeBytes();
    } on RemoteTileException {
      rethrow;
    } catch (_) {
      throw const RemoteTileException(
          'Network problem. Check your connection and try again.');
    }
  }

  bool _matches(Uint8List bytes, String expected) =>
      expected.isEmpty ||
      sha256.convert(bytes).toString() == expected.toLowerCase();

  /// Downloads one tile straight from the repo.
  Future<void> downloadTile(
    RemoteCatalog catalog,
    RemoteTile tile, {
    void Function(double progress)? onProgress,
  }) async {
    final bytes =
        await _download(catalog.fileUrl(tile), onProgress: onProgress);
    if (!_matches(bytes, tile.sha256)) {
      throw const RemoteTileException(
          'Downloaded file failed its checksum. Try again.');
    }
    await store.saveTiles([(tile, bytes)]);
  }

  /// Downloads a category zip and saves every tile in it.
  ///
  /// Returns [PackDownloadResult] so the caller can report partial failures.
  /// Throws only if the *whole* pack is unusable (bad zip, wrong checksum, or
  /// every tile failed verification).
  Future<PackDownloadResult> downloadPack(
    RemoteCatalog catalog,
    RemoteCategory category, {
    void Function(double progress)? onProgress,
  }) async {
    final pack = category.pack;
    if (pack == null) {
      throw const RemoteTileException('This category has no pack.');
    }

    final zipBytes =
        await _download(catalog.packUrl(pack), onProgress: onProgress);
    if (!_matches(zipBytes, pack.sha256)) {
      throw const RemoteTileException(
          'The pack is out of date or damaged. Refresh and try again.');
    }

    final Map<String, Uint8List> files;
    try {
      files = await _unzipInBackground(zipBytes);
    } catch (_) {
      throw const RemoteTileException('Could not open the pack.');
    }

    // The catalogue decides which tiles exist; the zip is just a bag of bytes.
    final items = <(RemoteTile, Uint8List)>[];
    final failed = <String>[];

    for (final tile in catalog.tilesIn(category.id)) {
      final bytes = files[tile.file.split('/').last];
      if (bytes == null || !_matches(bytes, tile.sha256)) {
        failed.add(tile.name);
        continue;
      }
      items.add((tile, bytes));
    }

    if (items.isEmpty) {
      throw RemoteTileException(
        failed.isEmpty
            ? 'The pack had no valid tiles in it.'
            : 'All ${failed.length} tiles failed verification. Refresh and try again.',
      );
    }

    await store.saveTiles(items);
    return (saved: items.length, failed: failed);
  }
}