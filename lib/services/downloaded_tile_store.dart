import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/remote_catalog.dart';
import '../models/tile.dart';

/// Files live in <app support>/remote_tiles/files/ and are listed in
/// <app support>/remote_tiles/downloaded_manifest.json.
class DownloadedTileStore {
  static const String _manifestName = 'downloaded_manifest.json';

  // Every read-modify-write of the manifest goes through this one queue, so
  // two downloads finishing at the same time can't overwrite each other.
  static Future<void> _queue = Future.value();

  static Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<Directory> _filesDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/remote_tiles/files');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _manifestFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/remote_tiles/$_manifestName');
  }

  Future<List<Map<String, dynamic>>> _readManifest() async {
    final file = await _manifestFile();
    if (!await file.exists()) return [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      final list =
          (decoded as Map<String, dynamic>)['tiles'] as List<dynamic>? ?? [];
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return []; // corrupt manifest: start fresh instead of crashing
    }
  }

  // Write to a temp file, then rename, so a crash can't leave half a manifest.
  Future<void> _writeManifest(List<Map<String, dynamic>> entries) async {
    final file = await _manifestFile();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'schemaVersion': 1, 'tiles': entries}),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  Tile _tileFromEntry(Map<String, dynamic> entry, String filesPath) {
    return Tile(
      id: entry['id'] as String,
      name: entry['name'] as String? ?? entry['id'] as String,
      path: '$filesPath/${entry['file']}',
      width: entry['width'] as int? ?? 0,
      height: entry['height'] as int? ?? 0,
      source: TileSource.downloaded,
    );
  }

  Future<List<Tile>> loadTiles() async {
    final entries = await _readManifest();
    if (entries.isEmpty) return const [];
    final filesPath = (await _filesDir()).path;

    final tiles = <Tile>[];
    for (final entry in entries) {
      final tile = _tileFromEntry(entry, filesPath);
      if (await File(tile.path).exists()) tiles.add(tile);
    }
    return tiles;
  }

  Future<Set<String>> downloadedIds() async {
    final tiles = await loadTiles();
    return tiles.map((t) => t.id).toSet();
  }

  String _fileNameFor(RemoteTile tile) {
    final safeId = tile.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dot = tile.file.lastIndexOf('.');
    final ext = dot == -1 ? '.png' : tile.file.substring(dot).toLowerCase();
    return '$safeId$ext';
  }

  /// Saves any number of tiles and updates the manifest once.
  Future<void> saveTiles(List<(RemoteTile, Uint8List)> items) {
    return _exclusive(() async {
      final filesDir = await _filesDir();
      final entries = await _readManifest();

      for (final (tile, bytes) in items) {
        final fileName = _fileNameFor(tile);
        await File('${filesDir.path}/$fileName')
            .writeAsBytes(bytes, flush: true);

        entries.removeWhere((e) => e['id'] == tile.id);
        entries.add({
          'id': tile.id,
          'name': tile.name,
          'file': fileName,
          'width': tile.width,
          'height': tile.height,
          'category': tile.category,
          'downloadedAt': DateTime.now().toUtc().toIso8601String(),
        });
      }
      await _writeManifest(entries);
    });
  }

  Future<void> delete(String id) {
    return _exclusive(() async {
      final entries = await _readManifest();
      final filesPath = (await _filesDir()).path;
      for (final entry in entries.where((e) => e['id'] == id)) {
        final file = File('$filesPath/${entry['file']}');
        if (await file.exists()) await file.delete();
      }
      entries.removeWhere((e) => e['id'] == id);
      await _writeManifest(entries);
    });
  }
}