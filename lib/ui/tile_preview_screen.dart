import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../models/current_wallpaper.dart';
import '../models/screen_info.dart';
import '../models/tile.dart';
import '../models/tiling_config.dart';
import '../models/wallpaper_mode.dart';
import '../models/wallpaper_target.dart';
import '../services/current_wallpaper_store.dart';
import '../services/tiler.dart';
import '../services/wallpaper_service.dart';
import '../utils/image_utils.dart';
import 'widgets/background_color_picker.dart';
import 'widgets/rotation_control.dart';

// -----------------------------------------------------------------------------
// TODO(scrolling-pages): The multi-page / "Enable scrolling" wallpaper mode
// has been temporarily removed from the UI — the feature is not feasible
// enough to keep exposing right now. The models (`CurrentWallpaper.pages`,
// `CurrentWallpaper.mode`, `WallpaperMode`) and the platform channel
// (`WallpaperService.setWallpaperFromFile`) still support it, so restoring
// the feature only requires re-adding the UI, preview, and apply paths
// marked with `TODO(scrolling-pages)` in this file.
//
// When re-enabling, the following needs to come back:
//   * `initialPages` / `initialMode` constructor params
//   * `_scrollingEnabled` state + "Enable scrolling" Switch
//   * `_pages` state + pages slider (and its hint)
//   * the horizontally-scrollable `_buildPreview` branch
//   * the page indicator pill in `_buildTopBar`
//   * `_onScrollingChanged`, `_onPagesChanged`, `_pagesSlider`
//   * multi-page render/apply logic in `_applyWallpaper` and `_renderAndSet`
// -----------------------------------------------------------------------------

class TilePreviewScreen extends StatefulWidget {
  final Tile tile;
  final int? initialColumns;

  /// When reopening a saved wallpaper, pass the previously-chosen background
  /// color so we don't override the user's choice with an auto-suggestion.
  final Color? initialBackgroundColor;

  /// Previously-saved pattern alignment. Fraction of a tile, range [-0.5, 0.5].
  final double? initialOffsetX;
  final double? initialOffsetY;

  /// Previously-saved tile rotation in whole degrees, range [-180, 180].
  /// Non-null when reopening an already-applied wallpaper for editing.
  final int? initialRotationDegrees;

  /// Non-null when this screen was opened to edit an already-applied
  /// wallpaper. Shows an "Editing …" badge under the top bar and a
  /// prominent "Update <target>" button above "Apply wallpaper to".
  final WallpaperTarget? editingTarget;

  // TODO(scrolling-pages): Restore `initialPages` / `initialMode` here once
  // the multi-page scrolling feature is reimplemented. They were previously
  // used to repopulate the pages slider and the "Enable scrolling" switch
  // when reopening an existing scrolling wallpaper.

  const TilePreviewScreen({
    super.key,
    required this.tile,
    this.initialColumns,
    this.initialBackgroundColor,
    this.initialOffsetX,
    this.initialOffsetY,
    this.initialRotationDegrees,
    this.editingTarget,
  });

  @override
  State<TilePreviewScreen> createState() => _TilePreviewScreenState();
}

class _TilePreviewScreenState extends State<TilePreviewScreen> {
  static const double _hudRadius = 8;
  static const int _minColumns = 1;
  static const int _maxColumns = 40;

  /// Range of the alignment offset, in fractional tiles.
  static const double _maxOffset = 0.5;

  /// Slider runs from -_maxRotation to +_maxRotation with this many divisions.
  /// 8 divisions × 45° steps = exactly 9 allowed angles: 0, ±45, ±90, ±135, ±180.
  /// These are the only angles at which a square tile's rotated bbox tiles
  /// seamlessly at its own period, so the slider is discrete.
  static const int _maxRotation = 180;
  static const int _rotationDivisions = 8;

  /// Rounds an arbitrary angle to the nearest allowed step. Used when
  /// reopening a wallpaper saved before discrete angles existed, or when the
  /// user types into the rotation text field.
  static int _snapRotation(int degrees) =>
      ((degrees.clamp(-_maxRotation, _maxRotation) / 45.0).round() * 45)
          .clamp(-_maxRotation, _maxRotation);

  final WallpaperService _wallpaperService = WallpaperService();
  final CurrentWallpaperStore _currentWallpaperStore = CurrentWallpaperStore();

  ui.Image? _sourceImage;
  ScreenInfo? _screen;
  String? _error;
  String? _status;

  int _columns = 8;

  bool _hasTransparency = false;
  Color _backgroundColor = const Color(0xFF000000);

  // Pattern alignment. Fraction of a tile, range [-0.5, 0.5].
  // Adjusted by dragging on the preview (see _onPreviewDragUpdate).
  double _offsetX = 0.0;
  double _offsetY = 0.0;

  // Tile rotation in whole degrees, range [-_maxRotation, _maxRotation].
  // Adjusted by the rotation slider / text field (see RotationControl).
  int _rotationDegrees = 0;

  // Debounced, pre-rotated version of `_sourceImage`. When non-null, the
  // preview painter uses it instead of `_sourceImage`. Rebuilt whenever
  // `_rotationDegrees` settles on a new value (see `_scheduleRotationRebuild`).
  ui.Image? _rotatedSourceImage;
  Timer? _rotateDebounce;

  bool _applying = false;
  bool _hudHidden = false;

  bool get _hasOffset => _offsetX.abs() > 0.001 || _offsetY.abs() > 0.001;

  @override
  void initState() {
    super.initState();

    _columns = widget.initialColumns ?? _columns;
    _offsetX = (widget.initialOffsetX ?? 0.0).clamp(-_maxOffset, _maxOffset);
    _offsetY = (widget.initialOffsetY ?? 0.0).clamp(-_maxOffset, _maxOffset);

    _rotationDegrees = _snapRotation(widget.initialRotationDegrees ?? 0);

    if (_columns < _minColumns) _columns = _minColumns;
    if (_columns > _maxColumns) _columns = _maxColumns;

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    _load();
  }

  @override
  void dispose() {
    _rotateDebounce?.cancel();
    _disposeRotated();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _sourceImage?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final image = await loadUiImageForTile(widget.tile);

      final screenFuture = _wallpaperService.getScreenInfo();
      final transparencyFuture = imageHasTransparency(image);

      final screen = await screenFuture;
      final hasTransparency = await transparencyFuture;

      if (!mounted) {
        image.dispose();
        return;
      }

      Color initialBg = const Color(0xFF000000);

      if (widget.initialBackgroundColor != null) {
        initialBg = widget.initialBackgroundColor!;
      } else if (hasTransparency) {
        final suggested = await suggestBackgroundColor(image);
        initialBg = Color(suggested);
        if (!mounted) {
          image.dispose();
          return;
        }
      }

      setState(() {
        _sourceImage = image;
        _screen = screen;
        _hasTransparency = hasTransparency;
        _backgroundColor = initialBg;
        // TODO(scrolling-pages): The suggested-page-count initialization
        // used to live here. It has been dropped because pages are now
        // hard-coded to 1 while the scrolling feature is on hold.
      });

      // When reopening a saved wallpaper for editing, the persisted angle
      // is non-zero; produce the rotated tile now so the first frame
      // already shows the correct pattern.
      if (_rotationDegrees != 0) {
        _rebuildRotatedSource();
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onColumnsChanged(int value) {
    if (value < _minColumns || value > _maxColumns) return;
    if (value == _columns) return;
    setState(() => _columns = value);
  }

  void _onBackgroundChanged(Color color) {
    if (color.value == _backgroundColor.value) return;
    HapticFeedback.selectionClick();
    setState(() => _backgroundColor = color);
  }

  // ---------------------------------------------------------------------------
  // Drag-to-align
  // ---------------------------------------------------------------------------
  //
  // Always enabled now that the horizontally-scrolling preview is gone —
  // every horizontal drag goes to the pattern alignment. When the
  // scrolling/multi-page feature returns, this must defer to the page
  // scroller again (see TODO(scrolling-pages) below).
  void _onPreviewDragUpdate(DragUpdateDetails details) {
    // TODO(scrolling-pages): Restore the `if (_effectivePages != 1) return;`
    // guard once the scrolling preview is back, so horizontal drags in
    // scrolling mode belong to the page scroller instead of the pattern.

    final content = _sourceImage;
    if (content == null) return;

    final display = MediaQuery.sizeOf(context);
    if (display.width <= 0) return;

    // The rotated source (if present) is what's actually tiled. Its bbox is
    // bigger than the content, and the tiler grows the cell accordingly, so
    // mirror that math here — otherwise drags at 45° under- or over-shoot.
    final tiledSource = _rotatedSourceImage ?? content;
    final contentW = content.width.toDouble();
    final sourceW = tiledSource.width.toDouble();
    final sourceH = tiledSource.height.toDouble();
    if (contentW <= 0 || sourceW <= 0 || sourceH <= 0) return;

    final tileDisplayWidth = (display.width / _columns) * (sourceW / contentW);
    final tileDisplayHeight = tileDisplayWidth * (sourceH / sourceW);
    if (tileDisplayWidth <= 0 || tileDisplayHeight <= 0) return;

    final nextX = (_offsetX - details.delta.dx / tileDisplayWidth)
        .clamp(-_maxOffset, _maxOffset);
    final nextY = (_offsetY - details.delta.dy / tileDisplayHeight)
        .clamp(-_maxOffset, _maxOffset);

    if ((nextX - _offsetX).abs() < 0.0005 &&
        (nextY - _offsetY).abs() < 0.0005) {
      return;
    }

    setState(() {
      _offsetX = nextX;
      _offsetY = nextY;
    });
  }

  void _resetAlignment() {
    if (!_hasOffset) return;
    HapticFeedback.selectionClick();
    setState(() {
      _offsetX = 0;
      _offsetY = 0;
    });
  }

  void _onRotationChanged(int value) {
    final snapped = _snapRotation(value);
    if (snapped == _rotationDegrees) return;
    setState(() => _rotationDegrees = snapped);
    _scheduleRotationRebuild();
  }

  void _resetRotation() {
    if (_rotationDegrees == 0) return;
    HapticFeedback.selectionClick();
    setState(() => _rotationDegrees = 0);
    _scheduleRotationRebuild();
  }

  /// Schedules a rebuild of `_rotatedSourceImage` ~80 ms after the last
  /// rotation change. Debouncing prevents rebuilding the tile on every tick
  /// of the slider drag. The slider's visual position still updates
  /// immediately (that's plain `setState`); only the *preview pixels*
  /// settle after the debounce.
  void _scheduleRotationRebuild() {
    _rotateDebounce?.cancel();
    _rotateDebounce = Timer(const Duration(milliseconds: 80), () {
      _rebuildRotatedSource();
    });
  }

  Future<void> _rebuildRotatedSource() async {
    final source = _sourceImage;
    if (source == null) return;

    if (_rotationDegrees == 0) {
      _disposeRotated();
      if (mounted) setState(() {});
      return;
    }

    final requested = _rotationDegrees;
    try {
      final needsFill = requested % 90 != 0;
      final rotated = await rotateTileImage(
        source,
        requested,
        maxDimension: 4096,
        fillCorners: needsFill,
      );

      if (!mounted) {
        rotated.dispose();
        return;
      }
      if (_rotationDegrees != requested) {
        rotated.dispose();
        return;
      }
      _disposeRotated();
      setState(() => _rotatedSourceImage = rotated);
    } catch (e) {
      debugPrint('Could not rotate tile image: $e');
    }
  }

  void _disposeRotated() {
    _rotatedSourceImage?.dispose();
    _rotatedSourceImage = null;
  }

  (int, int) _canvasSize(ScreenInfo screen, double scale) {
    // TODO(scrolling-pages): Restore the `pages` multiplier on the width when
    // the multi-page feature returns.
    return (
      (screen.screenWidth * scale).round(),
      (screen.screenHeight * scale).round(),
    );
  }

  Future<void> _saveCurrentWallpaper(WallpaperTarget target) async {
    try {
      // TODO(scrolling-pages): Restore the multi-page save path (pass the
      // user-selected page count and mode) once the "Enable scrolling"
      // feature comes back. Right now every save is a static, single-page
      // wallpaper.
      final wallpaper = CurrentWallpaper(
        tileId: widget.tile.id,
        columns: _columns,
        pages: 1,
        mode: WallpaperMode.singlePage,
        target: target,
        appliedAt: DateTime.now(),
        backgroundColor: _backgroundColor.value,
        offsetX: _offsetX,
        offsetY: _offsetY,
        rotationDegrees: _rotationDegrees,
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

    // Only pop the screen when the whole apply pipeline succeeded.
    var success = false;

    try {
      // TODO(scrolling-pages): Restore the `homePages = _effectivePages`
      // branch when the multi-page feature is re-enabled. For now every
      // target is always rendered as a single static page.
      if (target == WallpaperTarget.both) {
        // A single static image shared by both screens. Persist one record
        // per target so the two info bars each report the correct one.
        await _renderAndSet(source, screen, target: WallpaperTarget.both);
        await _saveCurrentWallpaper(WallpaperTarget.home);
        await _saveCurrentWallpaper(WallpaperTarget.lock);
      } else {
        await _renderAndSet(source, screen, target: target);
        await _saveCurrentWallpaper(target);
      }

      success = true;
    } catch (e) {
      if (mounted) {
        setState(() => _status = 'Could not apply wallpaper: $e');
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }

    // Only return to the grid on success. On failure the user stays on this
    // screen and sees the error message so they can retry.
    if (success && mounted) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _renderAndSet(
    ui.Image source,
    ScreenInfo screen, {
    required WallpaperTarget target,
  }) async {
    // TODO(scrolling-pages): Restore the multi-page render path. For now we
    // always render a single static page sized to the screen.
    final (rawWidth, rawHeight) = _canvasSize(screen, 1.0);
    final (width, height) = _capWallpaperSize(rawWidth, rawHeight);

    final image = await renderTiledImage(
      source: source,
      canvasWidth: width,
      canvasHeight: height,
      config: TilingConfig(
        columns: _columns,
        backgroundColor: _backgroundColor,
        offsetX: _offsetX,
        offsetY: _offsetY,
        rotationDegrees: _rotationDegrees,
      ),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final file =
          File('${tempDir.path}/floorpaper_${target.platformName}.png');
      await writeUiImageToFile(image, file);

      // TODO(scrolling-pages): Restore the `* pages` multiplier on the
      // width hint once multi-page renders are back.
      final sendHints = target != WallpaperTarget.lock;
      await _wallpaperService.setWallpaperFromFile(
        filePath: file.path,
        target: target,
        hintWidth: sendHints ? screen.screenWidth : null,
        hintHeight: sendHints ? screen.screenHeight : null,
      );
    } finally {
      image.dispose();
    }
  }

  String _targetDisplayName(WallpaperTarget target) {
    switch (target) {
      case WallpaperTarget.home:
        return 'Home screen';
      case WallpaperTarget.lock:
        return 'Lock screen';
      case WallpaperTarget.both:
        return 'Both screens';
    }
  }

  IconData _targetIcon(WallpaperTarget target) {
    switch (target) {
      case WallpaperTarget.home:
        return Icons.wallpaper;
      case WallpaperTarget.lock:
        return Icons.lock;
      case WallpaperTarget.both:
        return Icons.smartphone;
    }
  }

  (int, int) _capWallpaperSize(int width, int height) {
    const maxSide = AppConfig.maxWallpaperSide;
    final largest = width > height ? width : height;
    if (largest <= maxSide) return (width, height);
    final scale = maxSide / largest;
    return ((width * scale).round(), (height * scale).round());
  }

  Future<void> _onApplyPressed() async {
    final target = await showModalBottomSheet<WallpaperTarget>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Apply to', style: theme.textTheme.titleMedium),
                ),
              ),
              // TODO(scrolling-pages): Restore the "N page(s)" subtitle on
              // the Home option once the scrolling feature is back.
              ListTile(
                leading: const Icon(Icons.wallpaper),
                title: const Text('Home screen'),
                onTap: () => Navigator.pop(ctx, WallpaperTarget.home),
              ),
              ListTile(
                leading: const Icon(Icons.lock),
                title: const Text('Lock screen'),
                onTap: () => Navigator.pop(ctx, WallpaperTarget.lock),
              ),
              ListTile(
                leading: const Icon(Icons.smartphone),
                title: const Text('Both screens'),
                onTap: () => Navigator.pop(ctx, WallpaperTarget.both),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (target != null && mounted) {
      await _applyWallpaper(target);
    }
  }

  // ---------------------------------------------------------------------------
  // Visuals
  // ---------------------------------------------------------------------------

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
          color: Colors.black.withValues(alpha: 0.55),
          child: child,
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_error != null) {
      return Center(child: Text(_error!, textAlign: TextAlign.center));
    }

    final source = _sourceImage;
    if (source == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Use the pre-rotated image when one is ready; otherwise fall back to
    // the original. The painter itself no longer knows about rotation —
    // rotation is baked into `displaySource`.
    final displaySource = _rotatedSourceImage ?? source;
    final contentSize = Size(
      source.width.toDouble(),
      source.height.toDouble(),
    );

    // TODO(scrolling-pages): Restore the horizontally-scrolling preview
    // branch (a `SingleChildScrollView` in `Axis.horizontal` around a
    // `SizedBox(width: box.maxWidth * pages)` CustomPaint) once the
    // "Enable scrolling" feature returns. For now we always render a
    // single, static page.
    return SizedBox.expand(
      child: CustomPaint(
        painter: _PreviewPainter(
          source: displaySource,
          contentSize: contentSize,
          columns: _columns,
          backgroundColor: _backgroundColor,
          offsetX: _offsetX,
          offsetY: _offsetY,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // HUD
  // ---------------------------------------------------------------------------

  Widget _buildHud() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          _buildTopBar(),
          const Spacer(),
          _buildControlsPanel(),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
            // TODO(scrolling-pages): Restore the "Page X / Y" pill on the
            // right side of this row once multi-page preview is back.
          ],
        ),
        // Screen-context badge sits below the back button + tile name so it
        // never fights the "Page X / Y" pill for horizontal space.
        if (widget.editingTarget != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: _glass(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_targetIcon(widget.editingTarget!), size: 14),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Editing '
                          '${_targetDisplayName(widget.editingTarget!)} '
                          'wallpaper',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildControlsPanel() {
    final theme = Theme.of(context);

    return _glass(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // HUD hint ---------------------------------------------------------
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Hold down on the preview to hide controls/HUD',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),

          if (_applying) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 12),
          ],

          // TODO(scrolling-pages): Restore the "Enable scrolling" Switch row
          // (and the Pages slider + hint that appeared beneath it) once the
          // multi-page feature is reimplemented.

          // Columns (zoom) ----------------------------------------------------
          _controlLabelRow(
            label: 'Columns',
            value: '$_columns',
          ),
          _columnsSlider(),

          // Rotation (tile pattern angle) -------------------------------------
          const SizedBox(height: 4),
          RotationControl(
            value: _rotationDegrees,
            onChanged: _onRotationChanged,
            onReset: _resetRotation,
            min: -_maxRotation,
            max: _maxRotation,
            divisions: _rotationDivisions,
          ),

          // Alignment hint ----------------------------------------------------
          // A fixed-height row: the Reset button is always part of the layout
          // (Visibility + maintainSize), so showing/hiding it never changes
          // the panel's height.
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.open_with, // four-directional arrows
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _hasOffset
                      ? 'Pattern aligned · drag to fine-tune'
                      : 'Drag preview to align the pattern',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Visibility(
                visible: _hasOffset,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: _resetAlignment,
                  child: const Text('Reset'),
                ),
              ),
            ],
          ),

          // Background --------------------------------------------------------
          if (_hasTransparency) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  Icons.palette_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Background',
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 8),
            BackgroundColorPicker(
              value: _backgroundColor,
              onChanged: _onBackgroundChanged,
            ),
          ],

          // Apply -------------------------------------------------------------
          const SizedBox(height: 16),
          if (widget.editingTarget != null) ...[
            // Primary action when editing: re-apply to the same screen.
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _applying
                    ? null
                    : () => _applyWallpaper(widget.editingTarget!),
                icon: const Icon(Icons.save_outlined),
                label: Text(
                  'Update ${_targetDisplayName(widget.editingTarget!)}',
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Secondary action: push to a different screen via the picker sheet.
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                onPressed: _applying ? null : _onApplyPressed,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Apply wallpaper to'),
              ),
            ),
          ] else
            SizedBox(
              height: 48,
              child: FilledButton.icon(
                onPressed: _applying ? null : _onApplyPressed,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Apply wallpaper to'),
              ),
            ),

          // Status feedback (bottom) — only present when there is one, so the
          // persistent "hold to hide" hint lives cleanly at the top.
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(
              _status!,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A read-only label/value pair. Never editable — this is the only "counter"
  /// shown to the user for zoom and page count.
  Widget _controlLabelRow({
    required String label,
    required String value,
    bool highlighted = false,
  }) {
    final theme = Theme.of(context);

    final badgeBg = highlighted
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final badgeFg = highlighted
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    return Row(
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: badgeBg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (highlighted) ...[
                Icon(Icons.check, size: 12, color: badgeFg),
                const SizedBox(width: 2),
              ],
              Text(
                value,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: badgeFg,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _columnsSlider() {
    return Row(
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Fewer columns',
          icon: const Icon(Icons.zoom_in),
          onPressed: _columns > _minColumns
              ? () {
                  HapticFeedback.selectionClick();
                  _onColumnsChanged(_columns - 1);
                }
              : null,
        ),
        Expanded(
          child: _plainSlider(
            value: _columns.toDouble(),
            min: _minColumns.toDouble(),
            max: _maxColumns.toDouble(),
            divisions: _maxColumns - _minColumns,
            label: '$_columns',
            semanticLabel: 'columns',
            onChanged: (v) {
              final next = v.round();
              if (next != _columns) _onColumnsChanged(next);
            },
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'More columns',
          icon: const Icon(Icons.zoom_out),
          onPressed: _columns < _maxColumns
              ? () {
                  HapticFeedback.selectionClick();
                  _onColumnsChanged(_columns + 1);
                }
              : null,
        ),
      ],
    );
  }

  // TODO(scrolling-pages): Restore `_pagesSlider()` here once the Pages
  // control is needed again. It was the UI for `_pages` / `_onPagesChanged`.

  Widget _plainSlider({
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required String semanticLabel,
    required ValueChanged<double> onChanged,
  }) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        tickMarkShape: SliderTickMarkShape.noTickMark,
      ),
      child: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        semanticFormatterCallback: (v) => '${v.round()} $semanticLabel',
        onChanged: onChanged,
        onChangeEnd: (_) => HapticFeedback.selectionClick(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Root
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // TODO(scrolling-pages): Restore the `dragEnabled = !_scrollingEnabled`
    // condition once scrolling preview is back — in scrolling mode horizontal
    // drags belong to the page scroller. For now every drag aligns the
    // pattern because there is only ever one page.
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => FocusScope.of(context).unfocus(),
            onLongPressStart: (_) => setState(() => _hudHidden = true),
            onLongPressEnd: (_) => setState(() => _hudHidden = false),
            onLongPressCancel: () => setState(() => _hudHidden = false),
            onPanUpdate: _onPreviewDragUpdate,
            child: RepaintBoundary(child: _buildPreview()),
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

// -----------------------------------------------------------------------------
// Preview painter
// -----------------------------------------------------------------------------
//
// Paints the tile as a repeated ImageShader on every frame. This is what makes
// drag-to-align instant: no ui.Image is ever produced for the preview, so
// there is no GPU→CPU readback, no PNG encoding, and no async gap between an
// offset change and the pixels on screen. The wallpaper path still uses
// renderTiledImage() → writeUiImageToFile() so the saved file is unchanged.

class _PreviewPainter extends CustomPainter {
  final ui.Image source; // pre-rotated (or original if no rotation)
  final ui.Size contentSize; // original, un-rotated dimensions
  final int columns;
  final Color backgroundColor;
  final double offsetX;
  final double offsetY;

  _PreviewPainter({
    required this.source,
    required this.contentSize,
    required this.columns,
    required this.backgroundColor,
    required this.offsetX,
    required this.offsetY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || columns <= 0) return;

    final config = TilingConfig(
      columns: columns,
      backgroundColor: backgroundColor,
      offsetX: offsetX,
      offsetY: offsetY,
    );

    final matrix = buildTilingMatrix(
      sourceSize: Size(
        source.width.toDouble(),
        source.height.toDouble(),
      ),
      canvasSize: size,
      config: config,
      contentSize: contentSize,
    );

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = backgroundColor,
    );

    canvas.drawPaint(
      Paint()
        ..shader = ui.ImageShader(
          source,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          matrix,
          filterQuality: ui.FilterQuality.medium,
        ),
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.source != source ||
      old.contentSize != contentSize ||
      old.columns != columns ||
      old.backgroundColor != backgroundColor ||
      old.offsetX != offsetX ||
      old.offsetY != offsetY;
}