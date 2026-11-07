import 'dart:io';

import 'package:flutter/material.dart';

import '../models/current_wallpaper.dart';
import '../models/tile.dart';
import '../models/wallpaper_target.dart';
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

  // Scroll controller so we can snap back to the top after a wallpaper is
  // applied, revealing the "Current wallpaper" info card(s).
  final ScrollController _scrollController = ScrollController();

  /// Created lazily the first time two current-wallpaper entries exist, then
  /// kept for the widget's lifetime. Its initialPage is an arbitrary large
  /// even number so the user can swipe left or right from the outset; the
  /// actual item is picked via `index % entries.length` in the PageView, so
  /// the carousel is circular regardless of where they start.
  PageController? _carouselController;

  bool _initialLoading = true;
  String? _error;

  List<Tile> _tiles = [];
  CurrentWallpaper? _homeWallpaper;
  CurrentWallpaper? _lockWallpaper;

  // Local-tile search.
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searchActive = false;
  String _searchQuery = '';

  // Currently visible card in the home/lock carousel (0 = home, 1 = lock).
  // Tracked so the page-indicator dots can animate on swipe.
  int _carouselIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _carouselController?.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _initialLoading = true;
      _error = null;
    });

    try {
      final results = await Future.wait<Object?>([
        _repository.loadAllLocalTiles(),
        _currentWallpaperStore.loadFor(WallpaperTarget.home),
        _currentWallpaperStore.loadFor(WallpaperTarget.lock),
      ]);

      if (!mounted) return;

      setState(() {
        _tiles = results[0] as List<Tile>;
        _homeWallpaper = results[1] as CurrentWallpaper?;
        _lockWallpaper = results[2] as CurrentWallpaper?;
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

  Future<void> _refreshAll() async {
    try {
      final results = await Future.wait<Object?>([
        _repository.loadAllLocalTiles(),
        _currentWallpaperStore.loadFor(WallpaperTarget.home),
        _currentWallpaperStore.loadFor(WallpaperTarget.lock),
      ]);

      if (!mounted) return;

      setState(() {
        _tiles = results[0] as List<Tile>;
        _homeWallpaper = results[1] as CurrentWallpaper?;
        _lockWallpaper = results[2] as CurrentWallpaper?;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (_tiles.isEmpty) {
        setState(() => _error = '$e');
      }
    }
  }

  Future<void> _refreshCurrentOnly() async {
    try {
      final results = await Future.wait<Object?>([
        _currentWallpaperStore.loadFor(WallpaperTarget.home),
        _currentWallpaperStore.loadFor(WallpaperTarget.lock),
      ]);
      if (!mounted) return;
      setState(() {
        _homeWallpaper = results[0] as CurrentWallpaper?;
        _lockWallpaper = results[1] as CurrentWallpaper?;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _homeWallpaper = null;
        _lockWallpaper = null;
      });
    }
  }

  List<Tile> get _filteredTiles {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _tiles;
    return _tiles.where((t) => t.name.toLowerCase().contains(q)).toList();
  }

  void _toggleSearch() {
    if (_searchActive) {
      _searchController.clear();
      _searchFocus.unfocus();
      setState(() {
        _searchActive = false;
        _searchQuery = '';
      });
    } else {
      setState(() => _searchActive = true);
      // The search bar lives at the top of the scroll view; bring it into
      // view and focus it once the frame that builds it has landed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
      if (_scrollController.hasClients && _scrollController.offset > 0) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  /// Always present as the *first* sliver so the "pop down" animation is a
  /// pure height change on the top edge, pushing the info bar + grid down.
  Widget _buildSearchSliver() {
    return SliverToBoxAdapter(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        // Reveal from the top edge, not the middle — this is what makes it
        // feel like the bar "pops down" out of the app bar.
        alignment: Alignment.topCenter,
        clipBehavior: Clip.hardEdge,
        child: _searchActive
            ? Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search tiles',
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                              _searchFocus.requestFocus();
                            },
                          )
                        : null,
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  /// Called after returning from the preview screen. If a wallpaper was
  /// actually applied (i.e. a record's `appliedAt` changed), this:
  ///   1) scrolls the grid back to the top so the info bar(s) are visible, and
  ///   2) focuses the carousel on the target that was *just updated*, so the
  ///      user sees the fresh info bar instead of whichever one they happened
  ///      to be looking at before. When both targets changed, home wins.
  /// If the user only previewed and backed out, nothing changes.
  void _revealAppliedWallpaper({
    DateTime? previousHomeAppliedAt,
    DateTime? previousLockAppliedAt,
  }) {
    final homeChanged = _homeWallpaper != null &&
        _homeWallpaper!.appliedAt != previousHomeAppliedAt;
    final lockChanged = _lockWallpaper != null &&
        _lockWallpaper!.appliedAt != previousLockAppliedAt;

    if (!homeChanged && !lockChanged) return;

    // Both changed → show home by default. Only lock changed → show lock.
    final target = homeChanged ? WallpaperTarget.home : WallpaperTarget.lock;

    // Wait for the rebuild triggered by _refreshCurrentOnly() so the
    // controller is attached and the current-wallpaper sliver exists.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      _focusCarouselOn(target);

      if (!_scrollController.hasClients) return;
      if (_scrollController.offset <= 0) return;

      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Scrolls the circular carousel to the card for [target] (if it isn't
  /// already the visible one). Picks the shorter direction around the
  /// infinite PageView.
  ///
  /// Note: both Home and Lock always have a card now (either a current
  /// wallpaper or a "not set" placeholder), so the carousel is always at
  /// least two pages — no "single card, nothing to swipe" early return.
  void _focusCarouselOn(WallpaperTarget target) {
    final controller = _carouselController;
    if (controller == null || !controller.hasClients) return;

    final entries = _buildCarouselEntries();
    final targetIndex = entries.indexWhere((e) => e.target == target);
    if (targetIndex < 0) return;

    final currentPage =
        (controller.page ?? controller.initialPage.toDouble()).round();
    final currentMod = currentPage % entries.length;
    if (currentMod == targetIndex) return; // already showing it

    var delta = targetIndex - currentMod;
    if (delta > entries.length / 2) delta -= entries.length;
    if (delta < -entries.length / 2) delta += entries.length;

    controller.animateToPage(
      currentPage + delta,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openTileStore() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TileStoreScreen()),
    );
    if (mounted) _refreshAll();
  }

  Future<void> _openTilePreview(Tile tile) async {
    final prevHome = _homeWallpaper?.appliedAt;
    final prevLock = _lockWallpaper?.appliedAt;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TilePreviewScreen(tile: tile)),
    );
    if (!mounted) return;

    await _refreshCurrentOnly();
    _revealAppliedWallpaper(
      previousHomeAppliedAt: prevHome,
      previousLockAppliedAt: prevLock,
    );
  }

  Future<void> _openCurrentWallpaper(
      Tile tile, CurrentWallpaper current) async {
    final prevHome = _homeWallpaper?.appliedAt;
    final prevLock = _lockWallpaper?.appliedAt;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TilePreviewScreen(
          tile: tile,
          initialColumns: current.columns,
          // TODO(scrolling-pages): Re-add `initialPages` / `initialMode` here
          // once the multi-page scrolling feature is reimplemented on the
          // preview screen. For now the preview always renders a single
          // static page, regardless of what the saved record contains.
          initialBackgroundColor: Color(current.backgroundColor),
          initialOffsetX: current.offsetX,
          initialOffsetY: current.offsetY,
          initialRotationDegrees: current.rotationDegrees,
          editingTarget: current.target,
        ),
      ),
    );
    if (!mounted) return;

    await _refreshCurrentOnly();
    _revealAppliedWallpaper(
      previousHomeAppliedAt: prevHome,
      previousLockAppliedAt: prevLock,
    );
  }

  Widget _buildTileImage(Tile tile) {
    const cacheW = 360;
    if (tile.source == TileSource.downloaded) {
      return Image.file(
        File(tile.path),
        fit: BoxFit.cover,
        cacheWidth: cacheW,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26),
      );
    }
    return Image.asset(
      tile.path,
      fit: BoxFit.cover,
      cacheWidth: cacheW,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black26),
    );
  }

  Tile? _findTile(String id) {
    for (final tile in _tiles) {
      if (tile.id == id) return tile;
    }
    return null;
  }

  /// Always returns exactly two entries — Home first, then Lock — so the
  /// carousel can render a "not set" placeholder for whichever target the
  /// user hasn't configured yet.
  List<_CarouselEntry> _buildCarouselEntries() {
    final home = _homeWallpaper;
    final homeTile = home != null ? _findTile(home.tileId) : null;

    final lock = _lockWallpaper;
    final lockTile = lock != null ? _findTile(lock.tileId) : null;

    return [
      _CarouselEntry(
        target: WallpaperTarget.home,
        tile: homeTile,
        current: home,
      ),
      _CarouselEntry(
        target: WallpaperTarget.lock,
        tile: lockTile,
        current: lock,
      ),
    ];
  }

  /// Builds whichever card an entry represents: an actual current-wallpaper
  /// card if a record is loaded, or a "not set" placeholder otherwise.
  Widget _buildCarouselCard(_CarouselEntry entry) {
    final tile = entry.tile;
    final current = entry.current;

    if (tile != null && current != null) {
      return _CurrentWallpaperCard(
        tile: tile,
        current: current,
        imageBuilder: _buildTileImage,
        onTap: () => _openCurrentWallpaper(tile, current),
      );
    }

    return _PlaceholderWallpaperCard(
      target: entry.target,
      hasTiles: _tiles.isNotEmpty,
      // When there are no local tiles yet, tapping the placeholder is the
      // shortest path to the store — same destination as the AppBar's
      // "download more tiles" button.
      onTap: _tiles.isEmpty ? _openTileStore : null,
    );
  }

  /// The home/lock carousel followed by its page-indicator dots.
  ///
  /// This is never null: on a fresh install (no wallpaper set) it shows two
  /// placeholder cards that prompt the user to choose a tile (if local tiles
  /// exist) or open the tile store (if they don't).
  Widget _buildCurrentWallpaperSliver() {
    final entries = _buildCarouselEntries();

    _carouselController ??= PageController(initialPage: 1000);

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      sliver: SliverToBoxAdapter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 120,
              child: PageView.builder(
                controller: _carouselController,
                onPageChanged: (index) {
                  final mod = index % entries.length;
                  if (mod != _carouselIndex) {
                    setState(() => _carouselIndex = mod);
                  }
                },
                itemBuilder: (context, index) {
                  return _buildCarouselCard(entries[index % entries.length]);
                },
              ),
            ),
            const SizedBox(height: 8),
            _buildCarouselDots(entries.length),
          ],
        ),
      ),
    );
  }

  /// Animated "current page" dots. The active dot stretches into a pill so it
  /// reads instantly even on small screens.
  Widget _buildCarouselDots(int count) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == _carouselIndex ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == _carouselIndex
                  ? scheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Floorpaper'),
        actions: [
          IconButton(
            tooltip: _searchActive ? 'Close search' : 'Search tiles',
            icon: Icon(_searchActive ? Icons.close : Icons.search),
            onPressed: _toggleSearch,
          ),
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
    if (_initialLoading) return const _SkeletonGrid();

    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _loadInitial);
    }

    final filtered = _filteredTiles;
    final query = _searchQuery.trim();

    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    final bottomPadding = 16.0 + bottomInset;

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: CustomScrollView(
        controller: _scrollController,
        // Always scrollable so pull-to-refresh works even when the grid
        // doesn't overflow the viewport.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          _buildSearchSliver(),
          // Always present now — on a fresh install this renders the two
          // "not set" placeholder cards + page dots.
          _buildCurrentWallpaperSliver(),
          if (_tiles.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyView(onBrowse: _openTileStore),
            )
          else if (filtered.isEmpty && query.isNotEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    'No tiles match "$query".',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(8, 8, 8, bottomPadding),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.0,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _TileGridItem(
                    tile: filtered[index],
                    imageBuilder: _buildTileImage,
                    onTap: () => _openTilePreview(filtered[index]),
                  ),
                  childCount: filtered.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A single slot in the home/lock carousel. Either [tile] and [current] are
/// both populated (a real current-wallpaper record), or both are null (the
/// target is unset and a placeholder should render).
class _CarouselEntry {
  final WallpaperTarget target;
  final Tile? tile;
  final CurrentWallpaper? current;

  const _CarouselEntry({
    required this.target,
    this.tile,
    this.current,
  });
}

// -----------------------------------------------------------------------------
// Sub-widgets
// -----------------------------------------------------------------------------

class _TileGridItem extends StatelessWidget {
  final Tile tile;
  final Widget Function(Tile) imageBuilder;
  final VoidCallback onTap;

  const _TileGridItem({
    required this.tile,
    required this.imageBuilder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            imageBuilder(tile),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Text(
                tile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Colors.white),
              ),
            ),
            if (tile.source == TileSource.downloaded)
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  Icons.cloud_done,
                  size: 14,
                  color: Colors.white,
                  shadows: [
                    Shadow(color: Colors.black54, blurRadius: 4),
                  ],
                ),
              ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurrentWallpaperCard extends StatelessWidget {
  final Tile tile;
  final CurrentWallpaper current;
  final Widget Function(Tile) imageBuilder;
  final VoidCallback onTap;

  const _CurrentWallpaperCard({
    required this.tile,
    required this.current,
    required this.imageBuilder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Per-target title so the two cards are instantly distinguishable when
    // swiping between them.
    final label = current.target == WallpaperTarget.lock
        ? 'Lock screen wallpaper'
        : 'Home screen wallpaper';

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
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
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        current.configSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 120,
                // Render the thumbnail on the applied background so the user
                // sees what their wallpaper actually looks like.
                child: ColoredBox(
                  color: Color(current.backgroundColor),
                  child: imageBuilder(tile),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Shown in the home/lock carousel when the corresponding target has no
/// wallpaper set. Visually mirrors [_CurrentWallpaperCard] so the carousel
/// feels consistent whether you're looking at a real or unconfigured slot.
class _PlaceholderWallpaperCard extends StatelessWidget {
  final WallpaperTarget target;
  final bool hasTiles;
  final VoidCallback? onTap;

  const _PlaceholderWallpaperCard({
    required this.target,
    required this.hasTiles,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLock = target == WallpaperTarget.lock;

    final label = isLock ? 'Lock screen wallpaper' : 'Home screen wallpaper';
    final targetIcon = isLock ? Icons.lock_outline : Icons.wallpaper_outlined;

    // Two flavours of CTA, depending on whether the user can pick a tile
    // straight away (tiles exist) or first needs to fetch some.
    final subtitle = hasTiles
        ? 'Select a tile below to preview'
        : 'Download tiles to get started';

    // When there are no tiles, the preview block shows a cloud-download
    // glyph and the whole card becomes the "open the store" button.
    final previewIcon = hasTiles ? targetIcon : Icons.cloud_download_outlined;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: onTap,
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
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Not set',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 120,
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Icon(
                      previewIcon,
                      size: 40,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _EmptyView extends StatelessWidget {
  final VoidCallback onBrowse;
  const _EmptyView({required this.onBrowse});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.grid_view_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text('No tiles yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Download a pack to get started.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onBrowse,
              icon: const Icon(Icons.cloud_download_outlined),
              label: const Text('Browse tiles'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(
              'Could not load tiles.\n$message',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(8, 8, 8, 16 + bottomInset),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          // Square, matching the real grid.
          childAspectRatio: 1.0,
        ),
        itemCount: 12,
        itemBuilder: (_, __) => DecoratedBox(
          decoration: BoxDecoration(
            color: base.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}