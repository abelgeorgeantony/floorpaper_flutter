enum TileSource { bundled, downloaded }

class Tile {
  final String id;
  final String name;

  /// bundled: asset path (assets/tiles/x.png). downloaded: file path on the phone.
  final String path;
  final int width;
  final int height;
  final TileSource source;

  const Tile({
    required this.id,
    required this.name,
    required this.path,
    required this.width,
    required this.height,
    this.source = TileSource.bundled,
  });

  /// Entry from the bundled assets/tiles.json (that file still says "asset").
  factory Tile.fromJson(Map<String, dynamic> json) {
    return Tile(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['asset'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
    );
  }
}