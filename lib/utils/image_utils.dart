import 'dart:ui' as ui;

/// True if the image contains any pixel with meaningful translucency.
///
/// Renders a 64×64 bilinear downscale first so this stays ~O(4 KB) regardless
/// of the source size. Large transparent regions survive the downsample,
/// which is the case we care about (patterns with a transparent background).
Future<bool> imageHasTransparency(ui.Image image) async {
  const sampleSize = 64;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(
      0,
      0,
      sampleSize.toDouble(),
      sampleSize.toDouble(),
    ),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );

  final scaled = await recorder.endRecording().toImage(sampleSize, sampleSize);
  final byteData = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
  scaled.dispose();

  if (byteData == null) return false;

  final bytes = byteData.buffer.asUint8List(
    byteData.offsetInBytes,
    byteData.lengthInBytes,
  );

  // Alpha is every 4th byte in raw RGBA. Anything below ~250 counts as
  // transparent — the "2% slack" guards against 1-bit rounding artifacts
  // while still catching any real transparency.
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] < 250) return true;
  }
  return false;
}

/// Suggests a background color that makes the tile's opaque pixels visible.
///
/// Averages the Rec. 709 luma of non-transparent pixels. If the pattern is
/// darker than mid-gray we suggest white; otherwise we suggest black. This
/// makes the common "monochrome pattern on transparent" case look correct
/// out of the box.
Future<int> suggestBackgroundColor(ui.Image image) async {
  const sampleSize = 32;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(
      0,
      0,
      sampleSize.toDouble(),
      sampleSize.toDouble(),
    ),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );

  final scaled = await recorder.endRecording().toImage(sampleSize, sampleSize);
  final byteData = await scaled.toByteData(format: ui.ImageByteFormat.rawRgba);
  scaled.dispose();

  if (byteData == null) return 0xFF000000;

  final bytes = byteData.buffer.asUint8List(
    byteData.offsetInBytes,
    byteData.lengthInBytes,
  );

  var lumaSum = 0.0;
  var counted = 0;

  for (var i = 0; i < bytes.length; i += 4) {
    final a = bytes[i + 3];
    if (a < 32) continue; // ignore near-transparent pixels
    final r = bytes[i];
    final g = bytes[i + 1];
    final b = bytes[i + 2];
    lumaSum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
    counted++;
  }

  if (counted == 0) return 0xFF000000;

  final avgLuma = lumaSum / counted; // 0..255
  return avgLuma < 128 ? 0xFFFFFFFF : 0xFF000000;
}