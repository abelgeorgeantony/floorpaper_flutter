import 'wallpaper_mode.dart';
import 'wallpaper_target.dart';

class CurrentWallpaper {
  final String tileId;
  final int columns;

  /// TODO(scrolling-pages): Kept for backward compatibility when loading
  /// older saved records (which may have pages > 1). New saves always use
  /// `pages: 1` / `mode: singlePage` while the "Enable scrolling" feature
  /// is on hold.
  final int pages;

  /// TODO(scrolling-pages): See [pages]. Only meaningful for legacy records
  /// that were saved while multi-page scrolling was still exposed in the UI.
  final WallpaperMode mode;

  final WallpaperTarget target;
  final DateTime appliedAt;

  /// ARGB int (e.g. 0xFFFFFFFF for white). Backwards-compatible default
  /// is opaque black.
  final int backgroundColor;

  /// Pattern alignment, fraction of a tile. Range [-0.5, 0.5].
  final double offsetX;
  final double offsetY;

  /// Applied tile rotation in whole degrees. Range [-180, 180].
  /// Defaults to 0 so older saved records load without rotation.
  final int rotationDegrees;

  const CurrentWallpaper({
    required this.tileId,
    required this.columns,
    required this.pages,
    required this.mode,
    required this.target,
    required this.appliedAt,
    this.backgroundColor = 0xFF000000,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.rotationDegrees = 0,
  });

  String get configSummary {
    // TODO(scrolling-pages): Restore the pages/"All pages" display once the
    // scrolling feature is back. For now we only surface the column count,
    // so legacy multi-page records don't advertise a mode the app can no
    // longer reproduce.
    return 'Columns: $columns';
  }

  String get targetLabel {
    switch (target) {
      case WallpaperTarget.home:
        return 'Home';
      case WallpaperTarget.lock:
        return 'Lock';
      case WallpaperTarget.both:
        return 'Both';
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'tileId': tileId,
      'columns': columns,
      'pages': pages,
      'mode': mode.name,
      'target': target.name,
      'appliedAt': appliedAt.toIso8601String(),
      'backgroundColor': backgroundColor,
      'offsetX': offsetX,
      'offsetY': offsetY,
      'rotationDegrees': rotationDegrees,
    };
  }

  factory CurrentWallpaper.fromJson(Map<String, dynamic> json) {
    return CurrentWallpaper(
      tileId: json['tileId'] as String? ?? '',
      columns: json['columns'] as int? ?? 8,
      pages: json['pages'] as int? ?? 1,
      mode: WallpaperMode.values.firstWhere(
        (e) => e.name == json['mode'],
        orElse: () => WallpaperMode.singlePage,
      ),
      target: WallpaperTarget.values.firstWhere(
        (e) => e.name == json['target'],
        orElse: () => WallpaperTarget.home,
      ),
      appliedAt: DateTime.tryParse(json['appliedAt'] as String? ?? '') ??
          DateTime.now(),
      backgroundColor: json['backgroundColor'] as int? ?? 0xFF000000,
      offsetX: (json['offsetX'] as num?)?.toDouble() ?? 0.0,
      offsetY: (json['offsetY'] as num?)?.toDouble() ?? 0.0,
      rotationDegrees: (json['rotationDegrees'] as num?)?.toInt() ?? 0,
    );
  }
}