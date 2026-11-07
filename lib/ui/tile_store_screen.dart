import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/remote_catalog.dart';
import '../services/download_manager.dart';

class TileStoreScreen extends StatefulWidget {
  const TileStoreScreen({super.key});

  @override
  State<TileStoreScreen> createState() => _TileStoreScreenState();
}

class _TileStoreScreenState extends State<TileStoreScreen> {
  final DownloadManager _manager = DownloadManager.instance;

  late Future<RemoteCatalog> _catalogFuture = _loadCatalog();
  String? _selectedCategory;
  String _query = '';

  /// Tasks already reported via a snackbar. Prevents re-showing the same
  /// completion message on every manager notification, and ensures a toast
  /// is surfaced when the user returns to the store after a background
  /// download completed.
  final Set<String> _reportedTasks = {};

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManagerChanged);
    // Catch any tasks that completed while this screen was off-stack.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onManagerChanged());
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    // NOTE: deliberately do NOT dispose _manager.repository — that lives for
    // the whole app lifetime so background downloads survive this screen.
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;

    setState(() {});

    // Report finished tasks via snackbar, then clear them so the UI settles.
    for (final task in _manager.tasks.values.toList()) {
      if (task.status == DownloadStatus.running) continue;
      if (_reportedTasks.contains(task.key)) continue;
      _reportedTasks.add(task.key);

      final key = task.key;
      final message = task.message ??
          (task.status == DownloadStatus.success
              ? '${task.label} downloaded.'
              : 'Could not download ${task.label}.');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _reportedTasks.remove(key);
        _toast(message);
        _manager.clearTask(key);
      });
    }
  }

  Future<RemoteCatalog> _loadCatalog({bool forceRefresh = false}) async {
    final catalog =
        await _manager.repository.fetchCatalog(forceRefresh: forceRefresh);
    await _manager.refreshDownloadedIds();
    return catalog;
  }

  void _refresh() {
    setState(() {
      _selectedCategory = null;
      _query = '';
      _catalogFuture = _loadCatalog(forceRefresh: true);
    });
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _download(RemoteCatalog catalog, RemoteTile tile) {
    // Fire-and-forget: the manager handles progress + completion.
    _manager.downloadTile(catalog, tile);
  }

  void _downloadPack(RemoteCatalog catalog, RemoteCategory category) {
    _manager.downloadPack(catalog, category);
  }

  Future<void> _delete(RemoteTile tile) async {
    await _manager.repository.store.delete(tile.id);
    await _manager.refreshDownloadedIds();
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
        tiles.where((t) => !_manager.isDownloaded(t.id)).length;
    final task = _manager.taskFor('pack:${category.id}');

    final Widget action;
    if (task != null && task.status == DownloadStatus.running) {
      action = SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: task.progress > 0 ? task.progress : null,
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
    final task = _manager.taskFor(tile.id);

    if (task != null && task.status == DownloadStatus.running) {
      return SizedBox(
        height: 36,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: task.progress > 0 ? task.progress : null,
            ),
          ),
        ),
      );
    }

    if (_manager.isDownloaded(tile.id)) {
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