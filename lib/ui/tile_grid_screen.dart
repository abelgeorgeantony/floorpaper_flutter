import 'dart:io';

import 'package:flutter/material.dart';

import '../models/current_wallpaper.dart';
import '../models/tile.dart';
import '../services/current_wallpaper_store.dart';
import '../services/tile_repository.dart';
import 'tile_preview_screen.dart';
import 'tile_store_screen.dart';

class TileGridScreen extends StatefulWidget {
  const TileGridScreen({super.key});

  @override
  State<TileGridScreen> createState() => _TileGridScreenState();
}

class _TileGridScreenState extends State<TileGridScreen> {
  final TileRepository _repository = TileRepository();
  final CurrentWallpaperStore _currentWallpaperStore = CurrentWallpaperStore();

  bool _initialLoading = true;
  String? _error;

  List<Tile> _tiles = [];
  CurrentWallpaper? _current;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _initialLoading = true;
      _error = null;
    });

    try {
      final tilesFuture = _repository.loadAllLocalTiles();
      final currentFuture = _currentWallpaperStore.load();

      final tiles = await tilesFuture;
      final current = await currentFuture;

      if (!mounted) return;

      setState(() {
        _tiles = tiles;
        _current = current;
        _initialLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = '$e';
        _initialLoading = false;
      });
    }
  }

  /// Used after returning from the tile store, where tiles may be
  /// downloaded or deleted.
  Future<void> _refreshAll() async {
    try {
      final tilesFuture = _repository.loadAllLocalTiles();
      final currentFuture = _currentWallpaperStore.load();

      final tiles = await tilesFuture;
      final current = await currentFuture;

      if (!mounted) return;

      setState(() {
        _tiles = tiles;
        _current = current;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      // If we already have tiles, keep showing them instead of replacing
      // the whole screen with an error.
      if (_tiles.isEmpty) {
        setState(() => _error = '$e');
      }
    }
  }

  /// Used after returning from TilePreviewScreen.
  ///
  /// Applying a wallpaper does not change the tile list, so we only reload
  /// the tiny saved current-wallpaper config. This makes the current
  /// wallpaper card appear immediately after returning from preview.
  Future<void> _refreshCurrentOnly() async {
    try {
      final current = await _currentWallpaperStore.load();

      if (!mounted) return;

      setState(() => _current = current);
    } catch (_) {
      if (!mounted) return;

      setState(() => _current = null);
    }
  }

  Future<void> _openTileStore() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TileStoreScreen()),
    );

    if (mounted) {
      _refreshAll();
    }
  }

  Future<void> _openTilePreview(Tile tile) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TilePreviewScreen(tile: tile),
      ),
    );

    if (mounted) {
      _refreshCurrentOnly();
    }
  }

  Future<void> _openCurrentWallpaper(
    Tile tile,
    CurrentWallpaper current,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TilePreviewScreen(
          tile: tile,
          initialColumns: current.columns,
          initialPages: current.pages,
          initialMode: current.mode,
        ),
      ),
    );

    if (mounted) {
      _refreshCurrentOnly();
    }
  }

  Widget _tileImage(Tile tile) {
    if (tile.source == TileSource.downloaded) {
      return Image.file(
        File(tile.path),
        fit: BoxFit.cover,
        cacheWidth: 360,
        errorBuilder: (context, error, stackTrace) =>
            const ColoredBox(color: Colors.black26),
      );
    }

    return Image.asset(
      tile.path,
      fit: BoxFit.cover,
      cacheWidth: 360,
      errorBuilder: (context, error, stackTrace) =>
          const ColoredBox(color: Colors.black26),
    );
  }

  Widget _tileGridItem(Tile tile) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _tileImage(tile),
        if (tile.source == TileSource.downloaded)
          const Positioned(
            top: 4,
            right: 4,
            child: Icon(
              Icons.cloud_done,
              size: 16,
              color: Colors.white70,
              shadows: [
                Shadow(
                  color: Colors.black54,
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => _openTilePreview(tile),
          ),
        ),
      ],
    );
  }

  Widget _currentWallpaperCard(
    Tile tile,
    CurrentWallpaper current,
  ) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openCurrentWallpaper(tile, current),
        child: SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Current wallpaper',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        current.targetLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        current.configSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 120,
                child: _tileImage(tile),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Floorpaper'),

        // Prevent the Material 3 "scroll under" shade change.
        backgroundColor: Theme.of(context).colorScheme.surface,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,

        actions: [
          IconButton(
            tooltip: 'Download more tiles',
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: _openTileStore,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Error: $_error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loadInitial,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_tiles.isEmpty) {
      return const Center(child: Text('No tiles found.'));
    }

    final current = _current;
    Tile? currentTile;

    if (current != null) {
      for (final tile in _tiles) {
        if (tile.id == current.tileId) {
          currentTile = tile;
          break;
        }
      }
    }

    return CustomScrollView(
      slivers: [
        if (currentTile != null && current != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
            sliver: SliverToBoxAdapter(
              child: _currentWallpaperCard(currentTile, current),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.all(2),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _tileGridItem(_tiles[index]),
              childCount: _tiles.length,
            ),
          ),
        ),
      ],
    );
  }
}