class ScreenInfo {
  final int screenWidth;
  final int screenHeight;
  final int suggestedWidth;
  final int suggestedHeight;

  const ScreenInfo({
    required this.screenWidth,
    required this.screenHeight,
    required this.suggestedWidth,
    required this.suggestedHeight,
  });

  /// How many screens wide Android's suggested wallpaper is.
  int get suggestedPages => (suggestedWidth / screenWidth).round().clamp(1, 8);
}