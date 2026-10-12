import 'dart:io';

import 'dart:ui' as ui;

import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../models/tiling_config.dart';

import '../models/tile.dart';

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
}) {
  if (sourceSize.width <= 0 || sourceSize.height <= 0) {
    return const ui.Size(1, 1);
  }

  if (config.tileSize != null) {
    return config.tileSize!;
  }

  final canvasW = canvasSize.width;
  final canvasH = canvasSize.height;
  final sourceW = sourceSize.width;
  final sourceH = sourceSize.height;

  double tileW;
  double tileH;

  if (config.columns != null && config.rows != null) {
    tileW = canvasW / config.columns!;
    tileH = canvasH / config.rows!;
  } else if (config.columns != null) {
    tileW = canvasW / config.columns!;
    tileH = tileW * sourceH / sourceW;
  } else if (config.rows != null) {
    tileH = canvasH / config.rows!;
    tileW = tileH * sourceW / sourceH;
  } else {
    return sourceSize;
  }

  if (tileW < 1) tileW = 1;
  if (tileH < 1) tileH = 1;

  return ui.Size(tileW, tileH);
}

Future<ui.Image> renderTiledImage({
  required ui.Image source,
  required int canvasWidth,
  required int canvasHeight,
  required TilingConfig config,
}) async {
  final canvasSize = ui.Size(canvasWidth.toDouble(), canvasHeight.toDouble());
  final sourceSize = ui.Size(source.width.toDouble(), source.height.toDouble());

  final tileSize = computeTileSize(
    sourceSize: sourceSize,
    canvasSize: canvasSize,
    config: config,
  );

  // Scale the source straight to the exact tile size (no rounding).
  final matrix = Float64List.fromList([
    tileSize.width / source.width, 0, 0, 0,
    0, tileSize.height / source.height, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
  ]);

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, ui.Offset.zero & canvasSize);

  // Black behind transparent tiles.
  canvas.drawRect(
    ui.Offset.zero & canvasSize,
    ui.Paint()..color = const ui.Color(0xFF000000),
  );

  canvas.drawPaint(
    ui.Paint()
      ..shader = ui.ImageShader(
        source,
        ui.TileMode.repeated,
        ui.TileMode.repeated,
        matrix,
        filterQuality: ui.FilterQuality.medium,
      ),
  );

  final picture = recorder.endRecording();
  final output = await picture.toImage(canvasWidth, canvasHeight);
  picture.dispose();
  return output;
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