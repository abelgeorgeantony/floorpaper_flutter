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
  final Map<String, double> _progress = {}; // key: tile id, or "pack:<category id>"
  String? _selectedCategory; // null = all categories

  Future<RemoteCatalog> _loadCatalog() async {
    final catalog = await _repository.fetchCatalog();
    _downloaded = await _repository.store.downloadedIds();
    return catalog;
  }

  void _refresh() {
    setState(() {
      _selectedCategory = null;
      _catalogFuture = _loadCatalog();
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
      final count = await _repository.downloadPack(
        catalog,
        category,
        onProgress: (p) => _reportProgress(key, p),
      );
      _downloaded = await _repository.store.downloadedIds();
      if (!mounted) return;
      setState(() => _progress.remove(key));
      _toast('$count tiles added from ${category.name}.');
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
                    Text('${snapshot.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
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
    final tiles = selected == null ? catalog.tiles : catalog.tilesIn(selected);
    final category = selected == null ? null : catalog.categoryById(selected);

    return Column(
      children: [
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
                    onSelected: (_) => setState(() => _selectedCategory = null),
                  ),
                ),
                for (final c in catalog.categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(c.name),
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
              ? const Center(child: Text('No tiles in this category.'))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
    final missing = tiles.where((t) => !_downloaded.contains(t.id)).length;
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
      shape: const RoundedRectangleBorder(),
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
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
      shape: const RoundedRectangleBorder(),
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
                : Image.network(
                    thumbnail.toString(),
                    fit: BoxFit.cover,
                    cacheWidth: 300,
                    loadingBuilder: (context, child, chunk) =>
                        chunk == null ? child : Container(color: Colors.white10),
                    errorBuilder: (context, error, stack) => Container(
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
            const Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
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