import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/tile.dart';
import 'downloaded_tile_store.dart';

class TileRepository {
  final DownloadedTileStore _downloadedStore = DownloadedTileStore();

  Future<List<Tile>> loadBundledTiles() async {
    final jsonString = await rootBundle.loadString('assets/tiles.json');
    final decoded = jsonDecode(jsonString) as List<dynamic>;
    return decoded
        .map((item) => Tile.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<Tile>> loadDownloadedTiles() => _downloadedStore.loadTiles();

  /// Bundled tiles first, then anything the user downloaded.
  Future<List<Tile>> loadAllLocalTiles() async {
    final results = await Future.wait<List<Tile>>([
      loadBundledTiles(),
      loadDownloadedTiles(),
    ]);
    return [...results[0], ...results[1]];
  }
}