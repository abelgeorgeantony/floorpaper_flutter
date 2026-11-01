import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/remote_catalog.dart';
import '../services/remote_tile_repository.dart';

class TileStoreScreen extends StatefulWidget {
  const TileStoreScreen({super.key});

  @override
  State<TileStoreScreen> createState() => _TileStoreScreenState();
}

class _TileStoreScreenState extends State<TileStoreScreen> {
  final RemoteTileRepository _repository = RemoteTileRepository();

  late Future<RemoteCatalog> _catalogFuture = _loadCatalog();
  Set<String> _downloaded = {};
  final Map<String, double> _progress = {};
  String? _selectedCategory;
  String _query = '';

  @override
  void dispose() {
    _repository.dispose();
    super.dispose();
  }

  Future<RemoteCatalog> _loadCatalog({bool forceRefresh = false}) async {
    final catalog =
        await _repository.fetchCatalog(forceRefresh: forceRefresh);
    _downloaded = await _repository.store.downloadedIds();
    return catalog;
  }

  void _refresh() {
    setState(() {
      _selectedCategory = null;
      _query = '';
      _progress.clear();
      _catalogFuture = _loadCatalog(forceRefresh: true);
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _reportProgress(String key, double progress) {
    if (!mounted) return;
    final last = _progress[key] ?? 0;
    if (progress >= 1 || progress - last >= 0.02) {
      setState(() => _progress[key] = progress);
    }
  }

  Future<void> _download(RemoteCatalog catalog, RemoteTile tile) async {
    setState(() => _progress[tile.id] = 0);
    try {
      await _repository.downloadTile(
        catalog,
        tile,
        onProgress: (p) => _reportProgress(tile.id, p),
      );
      _downloaded = await _repository.store.downloadedIds();
      if (!mounted) return;
      setState(() => _progress.remove(tile.id));
      _toast('${tile.name} downloaded.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _progress.remove(tile.id));
      _toast('Could not download ${tile.name}: $e');
    }
  }

  Future<void> _downloadPack(
      RemoteCatalog catalog, RemoteCategory category) async {
    final key = 'pack:${category.id}';
    setState(() => _progress[key] = 0);
    try {
      final result = await _repository.downloadPack(
        catalog,
        category,
        onProgress: (p) => _reportProgress(key, p),
      );
      _downloaded = await _repository.store.downloadedIds();
      if (!mounted) return;
      setState(() => _progress.remove(key));

      if (result.failed.isEmpty) {
        _toast('${result.saved} tiles added from ${category.name}.');
      } else if (result.saved == 0) {
        _toast('Download failed for ${result.failed.length} tiles. Try again.');
      } else {
        _toast('${result.saved} added, ${result.failed.length} failed.');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _progress.remove(key));
      _toast('Could not download ${category.name}: $e');
    }
  }

  Future<void> _delete(RemoteTile tile) async {
    await _repository.store.delete(tile.id);
    if (!mounted) return;
    setState(() => _downloaded.remove(tile.id));
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  List<RemoteTile> _filterTiles(RemoteCatalog catalog) {
    final selected = _selectedCategory;
    final base =
        selected == null ? catalog.tiles : catalog.tilesIn(selected);
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((t) => t.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Download tiles'),
        actions: [
          IconButton(
            tooltip: 'Refresh catalogue',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<RemoteCatalog>(
        future: _catalogFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 48),
                    const SizedBox(height: 12),
                    Text('${snapshot.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          return _buildCatalog(snapshot.data!);
        },
      ),
    );
  }

  Widget _buildCatalog(RemoteCatalog catalog) {
    final selected = _selectedCategory;
    final tiles = _filterTiles(catalog);
    final category = selected == null ? null : catalog.categoryById(selected);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search tiles',
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (catalog.categories.isNotEmpty)
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: selected == null,
                    onSelected: (_) =>
                        setState(() => _selectedCategory = null),
                  ),
                ),
                for (final c in catalog.categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text('${c.name} (${catalog.tilesIn(c.id).length})'),
                      selected: selected == c.id,
                      onSelected: (_) =>
                          setState(() => _selectedCategory = c.id),
                    ),
                  ),
              ],
            ),
          ),
        if (category != null) _packBar(catalog, category),
        Expanded(
          child: tiles.isEmpty
              ? Center(
                  child: Text(
                    _query.isNotEmpty
                        ? 'No tiles match "${_query.trim()}".'
                        : 'No tiles in this category.',
                    textAlign: TextAlign.center,
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.62,
                  ),
                  itemCount: tiles.length,
                  itemBuilder: (context, index) =>
                      _tileCard(catalog, tiles[index]),
                ),
        ),
      ],
    );
  }

  Widget _packBar(RemoteCatalog catalog, RemoteCategory category) {
    final pack = category.pack;
    if (pack == null) return const SizedBox.shrink();

    final tiles = catalog.tilesIn(category.id);
    final missing =
        tiles.where((t) => !_downloaded.contains(t.id)).length;
    final progress = _progress['pack:${category.id}'];

    final Widget action;
    if (progress != null) {
      action = SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: progress > 0 ? progress : null,
        ),
      );
    } else if (missing == 0) {
      action = const Icon(Icons.check_circle_outline, color: Colors.green);
    } else {
      action = FilledButton.tonalIcon(
        onPressed: () => _downloadPack(catalog, category),
        icon: const Icon(Icons.download),
        label: const Text('Download all'),
      );
    }

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${category.name} pack',
                      style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    '${tiles.length} tiles · ${_formatSize(pack.sizeBytes)}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
            action,
          ],
        ),
      ),
    );
  }

  Widget _tileCard(RemoteCatalog catalog, RemoteTile tile) {
    final thumbnail = catalog.thumbnailUrl(tile);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: thumbnail == null
                ? Container(
                    color: Colors.white10,
                    child: const Icon(Icons.image_outlined),
                  )
                : CachedNetworkImage(
                    imageUrl: thumbnail.toString(),
                    fit: BoxFit.cover,
                    memCacheWidth: 300,
                    placeholder: (_, __) =>
                        Container(color: Colors.white10),
                    errorWidget: (_, __, ___) => Container(
                      color: Colors.white10,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(
                  _formatSize(tile.sizeBytes),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: _buildAction(catalog, tile),
          ),
        ],
      ),
    );
  }

  Widget _buildAction(RemoteCatalog catalog, RemoteTile tile) {
    final progress = _progress[tile.id];

    if (progress != null) {
      return SizedBox(
        height: 36,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: progress > 0 ? progress : null,
            ),
          ),
        ),
      );
    }

    if (_downloaded.contains(tile.id)) {
      return SizedBox(
        height: 36,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 18, color: Colors.green),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Delete download',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => _delete(tile),
            ),
          ],
        ),
      );
    }

    return SizedBox(
      height: 36,
      child: OutlinedButton(
        onPressed: () => _download(catalog, tile),
        child: const Icon(Icons.download, size: 18),
      ),
    );
  }
}