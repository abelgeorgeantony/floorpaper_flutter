import 'dart:ui';

class TilingConfig {
  final int? columns;
  final int? rows;
  final Size? tileSize;

  const TilingConfig({
    this.columns,
    this.rows,
    this.tileSize,
  });
}