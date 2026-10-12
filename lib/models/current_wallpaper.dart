import 'wallpaper_mode.dart';
import 'wallpaper_target.dart';

class CurrentWallpaper {
  final String tileId;
  final int columns;
  final int pages;
  final WallpaperMode mode;
  final WallpaperTarget target;
  final DateTime appliedAt;

  const CurrentWallpaper({
    required this.tileId,
    required this.columns,
    required this.pages,
    required this.mode,
    required this.target,
    required this.appliedAt,
  });

  String get configSummary {
    final pageText = mode == WallpaperMode.allPages
        ? 'Pages: $pages'
        : 'One page';

    return 'Columns: $columns · $pageText';
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
      appliedAt:
          DateTime.tryParse(json['appliedAt'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}