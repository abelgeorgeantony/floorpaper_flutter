import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/screen_info.dart';
import '../models/tile.dart';
import '../models/tiling_config.dart';
import '../models/wallpaper_mode.dart';
import '../models/wallpaper_target.dart';
import '../models/current_wallpaper.dart';
import '../services/current_wallpaper_store.dart';
import '../services/tiler.dart';
import '../services/wallpaper_service.dart';
import 'widgets/number_stepper.dart';

class TilePreviewScreen extends StatefulWidget {
  final Tile tile;
  final int? initialColumns;
  final int? initialPages;
  final WallpaperMode? initialMode;

  const TilePreviewScreen({
    super.key,
    required this.tile,
    this.initialColumns,
    this.initialPages,
    this.initialMode,
  });

  @override
  State<TilePreviewScreen> createState() => _TilePreviewScreenState();
}

class _TilePreviewScreenState extends State<TilePreviewScreen> {
  static const double _previewScale = 0.6; // preview quality vs. speed
  static const double _hudRadius = 8; // 0 = fully sharp
  static const int _minColumns = 1;
  static const int _maxColumns = 40;

  final WallpaperService _wallpaperService = WallpaperService();
  final CurrentWallpaperStore _currentWallpaperStore = CurrentWallpaperStore();

  ui.Image? _sourceImage;
  ui.Image? _previewImage;
  ScreenInfo? _screen;
  String? _error;
  String? _status;

  int _columns = 8; // columns per screen
  int _pages = 2;
  WallpaperMode _mode = WallpaperMode.singlePage;

  int _shownPages = 1; // pages in the image currently on screen
  int _currentPage = 0;
  int _previewJob = 0;

  bool _applying = false;
  bool _hudHidden = false;

  Timer? _debounce;

  int get _effectivePages => _mode == WallpaperMode.allPages ? _pages : 1;

  @override
  void initState() {
    super.initState();

    _columns = widget.initialColumns ?? _columns;
    _pages = widget.initialPages ?? _pages;
    _mode = widget.initialMode ?? _mode;

    if (_columns < 1) _columns = 1;
    if (_columns > 40) _columns = 40;

    if (_pages < 1) _pages = 1;
    if (_pages > 8) _pages = 8;

    if (_mode == WallpaperMode.allPages && _pages < 2) {
      _pages = 2;
    }

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _sourceImage?.dispose();
    _previewImage?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final image = await loadUiImageForTile(widget.tile);
      final screen = await _wallpaperService.getScreenInfo();

      if (!mounted) {
        image.dispose();
        return;
      }

      final hasInitialPages = widget.initialPages != null;

      setState(() {
        _sourceImage = image;
        _screen = screen;

        if (!hasInitialPages) {
          // "All pages" starts at what Android suggests (at least 2).
          _pages = screen.suggestedPages < 2 ? 2 : screen.suggestedPages;
        }
      });

      await _generatePreview();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _schedulePreview() {
    _status = null;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _generatePreview);
  }

  void _onColumnsChanged(int value) {
    if (value < _minColumns || value > _maxColumns) return;

    setState(() => _columns = value);
    _schedulePreview();
  }

  void _onPagesChanged(int value) {
    setState(() => _pages = value);
    _schedulePreview();
  }

  void _onModeChanged(WallpaperMode mode) {
    if (mode == _mode) return;

    setState(() {
      _mode = mode;

      if (_mode == WallpaperMode.allPages && _pages < 2) {
        _pages = 2;
      }
    });

    _schedulePreview();
  }

  void _zoomIn() {
    if (_columns > _minColumns) {
      _onColumnsChanged(_columns - 1);
    }
  }

  void _zoomOut() {
    if (_columns < _maxColumns) {
      _onColumnsChanged(_columns + 1);
    }
  }

  /// Pixel size of a wallpaper that is [pages] screens wide.
  (int, int) _canvasSize(ScreenInfo screen, int pages, double scale) {
    return (
      (screen.screenWidth * pages * scale).round(),
      (screen.screenHeight * scale).round(),
    );
  }

  Future<void> _generatePreview() async {
    final source = _sourceImage;
    final screen = _screen;
    if (source == null || screen == null) return;

    final pages = _effectivePages;
    final (width, height) = _canvasSize(screen, pages, _previewScale);
    final job = ++_previewJob;

    try {
      final image = await renderTiledImage(
        source: source,
        canvasWidth: width,
        canvasHeight: height,
        // "Columns" always means columns per screen, in both modes.
        config: TilingConfig(columns: _columns * pages),
      );

      // A newer request started, or the screen closed: drop this one.
      if (!mounted || job != _previewJob) {
        image.dispose();
        return;
      }

      final old = _previewImage;
      setState(() {
        _previewImage = image;
        _shownPages = pages;
        _currentPage = _currentPage.clamp(0, pages - 1);
      });
      old?.dispose();
    } catch (e) {
      debugPrint('Preview generation failed: $e');
    }
  }

  Future<void> _saveCurrentWallpaper(WallpaperTarget target) async {
    try {
      final mode =
          target == WallpaperTarget.lock ? WallpaperMode.singlePage : _mode;

      final pages = target == WallpaperTarget.lock ? 1 : _effectivePages;

      final wallpaper = CurrentWallpaper(
        tileId: widget.tile.id,
        columns: _columns,
        pages: pages,
        mode: mode,
        target: target,
        appliedAt: DateTime.now(),
      );

      await _currentWallpaperStore.save(wallpaper);
    } catch (e) {
      debugPrint('Could not save current wallpaper: $e');
    }
  }

  Future<void> _applyWallpaper(WallpaperTarget target) async {
    final source = _sourceImage;
    final screen = _screen;
    if (source == null || screen == null) return;

    setState(() {
      _applying = true;
      _status = null;
    });

    try {
      final homePages = _effectivePages;

      if (target == WallpaperTarget.both && homePages == 1) {
        // Same single-page image for both screens: render once.
        await _renderAndSet(source, screen,
            pages: 1, target: WallpaperTarget.both);
      } else {
        if (target != WallpaperTarget.lock) {
          await _renderAndSet(source, screen,
              pages: homePages, target: WallpaperTarget.home);
        }
        if (target != WallpaperTarget.home) {
          // The lock screen has no pages, so it always gets one page.
          await _renderAndSet(source, screen,
              pages: 1, target: WallpaperTarget.lock);
        }
      }

      await _saveCurrentWallpaper(target);

      if (mounted) setState(() => _status = 'Wallpaper applied.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not apply wallpaper: $e');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _renderAndSet(
    ui.Image source,
    ScreenInfo screen, {
    required int pages,
    required WallpaperTarget target,
  }) async {
    final (rawWidth, rawHeight) = _canvasSize(screen, pages, 1.0);
    final (width, height) = _capWallpaperSize(rawWidth, rawHeight);

    final image = await renderTiledImage(
      source: source,
      canvasWidth: width,
      canvasHeight: height,
      config: TilingConfig(columns: _columns * pages),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final file =
          File('${tempDir.path}/floorpaper_${target.platformName}.png');
      await writeUiImageToFile(image, file);

      // Only home/both tell Android how wide the wallpaper should be.
      final sendHints = target != WallpaperTarget.lock;
      await _wallpaperService.setWallpaperFromFile(
        filePath: file.path,
        target: target,
        hintWidth: sendHints ? screen.screenWidth * pages : null,
        hintHeight: sendHints ? screen.screenHeight : null,
      );
    } finally {
      image.dispose();
    }
  }

  (int, int) _capWallpaperSize(int width, int height) {
    const maxSide = 4096;

    final largest = width > height ? width : height;

    if (largest <= maxSide) {
      return (width, height);
    }

    final scale = maxSide / largest;

    return (
      (width * scale).round(),
      (height * scale).round(),
    );
  }

  Widget _glass({
    required Widget child,
    EdgeInsets padding = const EdgeInsets.all(12),
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(_hudRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          color: Colors.black.withValues(alpha: 0.45),
          child: child,
        ),
      ),
    );
  }

  Widget _labeled(String label, Widget child) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        child,
      ],
    );
  }

  Widget _columnsControl() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Columns: $_columns',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(width: 4),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Zoom in',
          icon: const Icon(Icons.zoom_in),
          onPressed: _columns > _minColumns ? _zoomIn : null,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Zoom out',
          icon: const Icon(Icons.zoom_out),
          onPressed: _columns < _maxColumns ? _zoomOut : null,
        ),
      ],
    );
  }

  Widget _buildPreview() {
    if (_error != null) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }

    final image = _previewImage;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_shownPages == 1) {
      return SizedBox.expand(
        child: RawImage(
          image: image,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        ),
      );
    }

    // All pages: swipe sideways one screen at a time, like the home screen.
    return LayoutBuilder(
      builder: (context, box) {
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollUpdateNotification &&
                n.metrics.viewportDimension > 0) {
              final page = (n.metrics.pixels / n.metrics.viewportDimension)
                  .round()
                  .clamp(0, _shownPages - 1);
              if (page != _currentPage) setState(() => _currentPage = page);
            }
            return false;
          },
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const PageScrollPhysics(),
            child: SizedBox(
              width: box.maxWidth * _shownPages,
              height: box.maxHeight,
              child: RawImage(
                image: image,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHud() {
    final screen = _screen;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              _glass(
                padding: EdgeInsets.zero,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: _glass(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Text(
                    widget.tile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const Spacer(),
              if (_shownPages > 1)
                _glass(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Text('Page ${_currentPage + 1} / $_shownPages'),
                ),
            ],
          ),
          const Spacer(),
          _glass(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_applying)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                SegmentedButton<WallpaperMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: WallpaperMode.singlePage,
                      icon: Icon(Icons.stay_current_portrait),
                      label: Text('One page'),
                    ),
                    ButtonSegment(
                      value: WallpaperMode.allPages,
                      icon: Icon(Icons.view_carousel_outlined),
                      label: Text('All pages'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => _onModeChanged(s.first),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _columnsControl(),
                    if (_mode == WallpaperMode.allPages)
                      _labeled(
                        'Pages',
                        NumberStepper(
                          value: _pages,
                          min: 2,
                          max: 8,
                          onChanged: _onPagesChanged,
                        ),
                      ),
                  ],
                ),
                if (_mode == WallpaperMode.allPages && screen != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Android suggests ${screen.suggestedPages} page(s) for this phone',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _applying
                            ? null
                            : () => _applyWallpaper(WallpaperTarget.home),
                        icon: const Icon(Icons.wallpaper),
                        label: const Text('Home'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _applying
                            ? null
                            : () => _applyWallpaper(WallpaperTarget.lock),
                        icon: const Icon(Icons.lock),
                        label: const Text('Lock'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _applying
                            ? null
                            : () => _applyWallpaper(WallpaperTarget.both),
                        icon: const Icon(Icons.check),
                        label: const Text('Both'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _status ?? 'Hold anywhere to hide the controls',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false, // keep the preview still when typing
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => FocusScope.of(context).unfocus(),
            onLongPressStart: (_) => setState(() => _hudHidden = true),
            onLongPressEnd: (_) => setState(() => _hudHidden = false),
            onLongPressCancel: () => setState(() => _hudHidden = false),
            child: _buildPreview(),
          ),
          AnimatedOpacity(
            opacity: _hudHidden ? 0 : 1,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: _hudHidden,
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: SafeArea(child: _buildHud()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
