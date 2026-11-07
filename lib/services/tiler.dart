import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../models/tile.dart';
import '../models/tiling_config.dart';

Future<ui.Image> loadUiImageFromAsset(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  final bytes = data.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );

  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

ui.Size computeTileSize({
  required ui.Size sourceSize,
  required ui.Size canvasSize,
  required TilingConfig config,
  ui.Size? contentSize,
}) {
  if (sourceSize.width <= 0 || sourceSize.height <= 0) {
    return const ui.Size(1, 1);
  }
  if (config.tileSize != null) return config.tileSize!;

  final canvasW = canvasSize.width;
  final canvasH = canvasSize.height;
  final sourceW = sourceSize.width;
  final sourceH = sourceSize.height;

  // "contentSize" is the *un-rotated* source size. At 45°/135° the source
  // is the bigger rotated bbox; we use contentSize to scale the cell by the
  // same expansion factor, so the *content* appears at its original size.
  final contentW = contentSize?.width ?? sourceW;
  final contentH = contentSize?.height ?? sourceH;

  double tileW;
  double tileH;

  if (config.columns != null && config.rows != null) {
    // Explicit grid — honour the user's dimensions, don't auto-grow.
    tileW = canvasW / config.columns!;
    tileH = canvasH / config.rows!;
  } else if (config.columns != null) {
    final scale = (canvasW / config.columns!) / contentW;
    tileW = sourceW * scale;
    tileH = sourceH * scale;
  } else if (config.rows != null) {
    final scale = (canvasH / config.rows!) / contentH;
    tileW = sourceW * scale;
    tileH = sourceH * scale;
  } else {
    return sourceSize;
  }

  if (tileW < 1) tileW = 1;
  if (tileH < 1) tileH = 1;
  return ui.Size(tileW, tileH);
}

/// Builds the 4×4 column-major matrix passed to [ui.ImageShader].
///
/// The matrix maps **image space → canvas space** with scale + offset only.
/// Rotation is *not* applied here. Instead, callers pass a pre-rotated
/// source image (see [rotateTileImage]) so the tiling grid stays
/// axis-aligned while each tile appears rotated.
Float64List buildTilingMatrix({
  required ui.Size sourceSize,
  required ui.Size canvasSize,
  required TilingConfig config,
  ui.Size? contentSize,
}) {
  final tileSize = computeTileSize(
    sourceSize: sourceSize,
    canvasSize: canvasSize,
    config: config,
    contentSize: contentSize,
  );

  final tx = -config.offsetX * tileSize.width;
  final ty = -config.offsetY * tileSize.height;

  return Float64List.fromList([
    tileSize.width / sourceSize.width,
    0,
    0,
    0,
    0,
    tileSize.height / sourceSize.height,
    0,
    0,
    0,
    0,
    1,
    0,
    tx,
    ty,
    0,
    1,
  ]);
}

/// Rotates [source] around its center by [degrees] (whole, wrapped into
/// [0, 360)) and returns a new [ui.Image] containing the rotated content.
///
/// - `0°` returns [source] unchanged (no allocation — the caller must
///   check for reference equality before disposing).
/// - `90°` / `180°` / `270°` are **pure pixel permutations**. No resampling
///   happens, so we deliberately skip supersampling for these angles and
///   return a pixel-exact rotation (dimensions swap for 90° and 270°).
///   The tile still tiles seamlessly when the original was seamless.
/// - Arbitrary angles (notably **45° and 135°**) expand to the rotated
///   bounding box. These DO involve resampling, so the rotation is rendered
///   at [supersample]× the final bbox resolution and then downsampled —
///   an SSAA-style antialiasing pass that preserves much more of the tile's
///   fine detail than a single bilinear tap per output pixel would.
///
/// [supersample] is automatically forced back to 1 for right‑angle rotations
/// and for intermediates that would exceed [maxDimension].
///
/// [fillCorners] (only meaningful for non‑90° angles) replaces the
/// transparent bbox corners with the wrapped source pattern so the rotated
/// tile is genuinely seamless at the bbox period.
///
/// [maxDimension] caps the longest output side (default 4096).
Future<ui.Image> rotateTileImage(
  ui.Image source,
  int degrees, {
  int maxDimension = 4096,
  bool fillCorners = false,
  int supersample = 2,
}) async {
  final normalized = ((degrees % 360) + 360) % 360;
  if (normalized == 0) return source;

  final isRightAngle = normalized % 90 == 0;

  final radians = normalized * math.pi / 180.0;
  final cosT = math.cos(radians).abs();
  final sinT = math.sin(radians).abs();

  final srcW = source.width.toDouble();
  final srcH = source.height.toDouble();

  final bboxW = srcW * cosT + srcH * sinT;
  final bboxH = srcW * sinT + srcH * cosT;

  var scale = 1.0;
  final longest = math.max(bboxW, bboxH);
  if (longest > maxDimension) {
    scale = maxDimension / longest;
  }

  final outW = (bboxW * scale).round().clamp(1, 1 << 20);
  final outH = (bboxH * scale).round().clamp(1, 1 << 20);

  // Right angles (90/180/270) are exact pixel permutations. Supersampling
  // them would force the result through a 2× downsample afterwards, and
  // that downsample is not a box filter (FilterQuality.high is cubic), so
  // it visibly blurs the perfectly pixel-aligned 90° image. Skip the
  // supersample pass entirely for these angles so the rotation stays exact.
  int ss = isRightAngle ? 1 : (supersample < 1 ? 1 : supersample);
  if (ss > 1) {
    final longestOut = outW > outH ? outW : outH;
    if (longestOut * ss > maxDimension) {
      ss = (maxDimension / longestOut).floor();
      if (ss < 1) ss = 1;
    }
  }
  final ssW = outW * ss;
  final ssH = outH * ss;

  // ---- Pass 1: draw the rotation (at supersampled resolution when ss > 1).
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  if (ss > 1) canvas.scale(ss.toDouble());
  canvas.translate(outW / 2, outH / 2);
  canvas.rotate(normalized * math.pi / 180.0);
  canvas.scale(scale, scale);

  if (fillCorners) {
    // Fill the entire rotated bbox with wrapped source content. Because the
    // source is drawn via a repeated ImageShader, the pixels that would have
    // been transparent corners of the rotated square are instead filled with
    // the pattern that continues from the opposite edge. For a seamless
    // source at 45°/135° this produces a genuinely seamless tile at the
    // bbox period — no gaps, no shrink.
    //
    // The draw rect is deliberately huge; the shader's TileMode handles the
    // wrapping, so any size that covers the output bounds works.
    canvas.drawRect(
      ui.Rect.fromLTWH(
        -outW.toDouble() - srcW,
        -outH.toDouble() - srcH,
        (outW + srcW) * 2.0,
        (outH + srcH) * 2.0,
      ),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..shader = ui.ImageShader(
          source,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          Float64List.fromList([
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            -srcW / 2,
            -srcH / 2,
            0,
            1,
          ]),
          filterQuality: ui.FilterQuality.high,
        ),
    );
  } else {
    // Original behaviour: draw the source once, transparent bbox corners.
    canvas.drawImage(
      source,
      ui.Offset(-srcW / 2, -srcH / 2),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
  }

  final picture = recorder.endRecording();
  final intermediate = await picture.toImage(ssW, ssH);
  picture.dispose();

  if (ss == 1) return intermediate;

  // ---- Pass 2: downsample the supersampled rotation to the bbox size.
  // This is only reached for non-90° angles, where the extra antialiasing
  // actually pays off. Right-angle rotations take the early `return` above
  // and stay pixel-exact.
  final finalRecorder = ui.PictureRecorder();
  final finalCanvas = ui.Canvas(finalRecorder);
  finalCanvas.drawImageRect(
    intermediate,
    ui.Rect.fromLTWH(0, 0, ssW.toDouble(), ssH.toDouble()),
    ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final finalPicture = finalRecorder.endRecording();
  final result = await finalPicture.toImage(outW, outH);
  finalPicture.dispose();
  intermediate.dispose();
  return result;
}

/// Renders a tiled image.
///
/// [previewPaddingPx] (default 0) inflates the output by this many pixels on
/// every side so the caller can display the pattern *continuing* past the
/// actual wallpaper bounds — the "boundary cache". Inside the inflated canvas
/// a thin white border is drawn exactly at the wallpaper bounds, and (when
/// [previewDimOutside] is true) the area outside the border is dimmed so the
/// boundary is obvious.
///
/// The final wallpaper render must always pass `previewPaddingPx: 0`.
Future<ui.Image> renderTiledImage({
  required ui.Image source,
  required int canvasWidth,
  required int canvasHeight,
  required TilingConfig config,
  int previewPaddingPx = 0,
  bool previewDimOutside = true,
}) async {
  // Fill corners only at 45°/135° — the angles where the bbox is a genuine
  // fundamental domain of the rotated lattice. At 90° multiples bbox ==
  // source, so we skip the shader entirely.
  final needsFill =
      config.rotationDegrees != 0 && config.rotationDegrees % 90 != 0;

  final rotatedSource = config.rotationDegrees == 0
      ? source
      : await rotateTileImage(
          source,
          config.rotationDegrees,
          fillCorners: needsFill,
        );

  try {
    final pad = previewPaddingPx < 0 ? 0 : previewPaddingPx;
    final outputWidth = canvasWidth + pad * 2;
    final outputHeight = canvasHeight + pad * 2;
    final outputSize = ui.Size(outputWidth.toDouble(), outputHeight.toDouble());

    final logicalCanvasSize =
        ui.Size(canvasWidth.toDouble(), canvasHeight.toDouble());

    final rotatedSourceSize = ui.Size(
      rotatedSource.width.toDouble(),
      rotatedSource.height.toDouble(),
    );

    // Original (pre-rotation) dimensions — the "true size" of the content.
    final contentSize = ui.Size(
      source.width.toDouble(),
      source.height.toDouble(),
    );

    final matrix = buildTilingMatrix(
      sourceSize: rotatedSourceSize,
      canvasSize: logicalCanvasSize,
      config: config,
      contentSize: contentSize,
    );

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, ui.Offset.zero & outputSize);

    // Backdrop for transparent corners of rotated tiles.
    canvas.drawRect(
      ui.Offset.zero & outputSize,
      ui.Paint()..color = config.backgroundColor,
    );

    // Tiled pattern across the entire (possibly padded) canvas.
    canvas.drawPaint(
      ui.Paint()
        ..shader = ui.ImageShader(
          rotatedSource,
          ui.TileMode.repeated,
          ui.TileMode.repeated,
          matrix,
          filterQuality: ui.FilterQuality.high,
        ),
    );

    // Preview-only chrome: dim outside + border at the wallpaper bounds.
    if (pad > 0) {
      final padF = pad.toDouble();
      final innerRect = ui.Rect.fromLTWH(
        padF,
        padF,
        canvasWidth.toDouble(),
        canvasHeight.toDouble(),
      );

      if (previewDimOutside) {
        final outerPath = ui.Path()..addRect(ui.Offset.zero & outputSize);
        outerPath.addRect(innerRect);
        outerPath.fillType = ui.PathFillType.evenOdd;
        canvas.drawPath(
          outerPath,
          ui.Paint()..color = const ui.Color(0x80000000),
        );
      }

      canvas.drawRect(
        innerRect,
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const ui.Color(0xCCFFFFFF),
      );
    }

    final picture = recorder.endRecording();
    final output = await picture.toImage(outputWidth, outputHeight);
    picture.dispose();
    return output;
  } finally {
    if (rotatedSource != source) {
      rotatedSource.dispose();
    }
  }
}

Future<void> disposeImage(ui.Image? image) async {
  image?.dispose();
}

Future<File> writeUiImageToFile(
  ui.Image image,
  File file,
) async {
  final byteData = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );

  if (byteData == null) {
    throw StateError('Could not encode wallpaper image.');
  }

  await file.writeAsBytes(
    byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    ),
    flush: true,
  );

  return file;
}

Future<ui.Image> loadUiImageFromFile(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// Loads a tile from wherever it lives (bundled asset or downloaded file).
Future<ui.Image> loadUiImageForTile(Tile tile) {
  return tile.source == TileSource.bundled
      ? loadUiImageFromAsset(tile.path)
      : loadUiImageFromFile(tile.path);
}