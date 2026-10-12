enum WallpaperTarget {
  home,
  lock,
  both;

  String get platformName {
    switch (this) {
      case WallpaperTarget.home:
        return 'home';
      case WallpaperTarget.lock:
        return 'lock';
      case WallpaperTarget.both:
        return 'both';
    }
  }
}