import 'dart:ui';

class TilingConfig {
  final int? columns;
  final int? rows;
  final Size? tileSize;

  /// Filled behind the tile shader. Transparent tiles reveal this color.
  final Color backgroundColor;

  /// Pattern shift as a fraction of one tile's width.
  /// Range [-0.5, 0.5]. Positive shifts the pattern right.
  /// Fractional (not absolute px) so the alignment survives column changes.
  final double offsetX;

  /// Pattern shift as a fraction of one tile's height.
  /// Range [-0.5, 0.5]. Positive shifts the pattern down.
  final double offsetY;

  /// Applied tile rotation in whole degrees. Range [-180, 180]. 0 = no rotation.
  ///
  /// This is the angle that the *tile image itself* is rotated by. The tiler
  /// rotates the source tile around its center with [rotateTileImage] and
  /// then tiles the rotated image with an axis-aligned matrix — so the grid
  /// stays rectangular while each tile appears rotated. Positive values
  /// rotate the tile clockwise on screen; negative counter-clockwise.
  final int rotationDegrees;

  const TilingConfig({
    this.columns,
    this.rows,
    this.tileSize,
    this.backgroundColor = const Color(0xFF000000),
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.rotationDegrees = 0,
  });
}
