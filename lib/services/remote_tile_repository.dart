import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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

class RemoteTileRepository {
  RemoteTileRepository({DownloadedTileStore? store})
      : store = store ?? DownloadedTileStore();

  final DownloadedTileStore store;

  /// CHANGE THIS: your GitHub username.
  static const String metadataUrl =
      'https://raw.githubusercontent.com/abelgeorgeantony/tiles-archive/main/metadata.json';

  Future<RemoteCatalog> fetchCatalog() async {
    try {
      final response = await http
          .get(Uri.parse(metadataUrl))
          .timeout(const Duration(seconds: 20));
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

  Future<Uint8List> _download(
    Uri url, {
    void Function(double progress)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', url)) // follows the GitHub redirect
          .timeout(const Duration(seconds: 30));
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
    } finally {
      client.close();
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
    final bytes = await _download(catalog.fileUrl(tile), onProgress: onProgress);
    if (!_matches(bytes, tile.sha256)) {
      throw const RemoteTileException(
          'Downloaded file failed its checksum. Try again.');
    }
    await store.saveTiles([(tile, bytes)]);
  }

  /// Downloads a category zip and saves every tile in it. Returns how many.
  Future<int> downloadPack(
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
    for (final tile in catalog.tilesIn(category.id)) {
      final bytes = files[tile.file.split('/').last];
      if (bytes == null || !_matches(bytes, tile.sha256)) continue;
      items.add((tile, bytes));
    }
    if (items.isEmpty) {
      throw const RemoteTileException('The pack had no valid tiles in it.');
    }

    await store.saveTiles(items);
    return items.length;
  }
}