/// Central place for compile-time-overridable config.
///
/// Override at build time, e.g.:
///   flutter build appbundle \
///     --dart-define=TILE_METADATA_URL=https://example.com/test.json
class AppConfig {
  AppConfig._();

  /// Where the remote catalogue lives.
  static const String metadataUrl = String.fromEnvironment(
    'TILE_METADATA_URL',
    defaultValue:
        'https://raw.githubusercontent.com/abelgeorgeantony/tiles-archive/main/metadata.json',
  );

  /// How long a cached metadata.json is considered fresh.
  static const Duration catalogCacheTtl = Duration(hours: 24);

  /// Timeout for the initial catalogue request.
  static const Duration catalogTimeout = Duration(seconds: 20);

  /// Timeout for downloading a tile or pack.
  static const Duration downloadTimeout = Duration(seconds: 30);

  /// Debounce between preview render requests while the user drags.
  static const Duration previewDebounce = Duration(milliseconds: 150);

  /// Longer debounce used when the pattern is dense (many columns).
  static const Duration previewDebounceHeavy = Duration(milliseconds: 220);

  /// Threshold above which we switch to the heavier debounce.
  static const int heavyColumnsThreshold = 24;

  /// Maximum wallpaper side length before downscaling. Prevents OOM
  /// on phones when the user requests 8 home-screen pages.
  static const int maxWallpaperSide = 4096;
}