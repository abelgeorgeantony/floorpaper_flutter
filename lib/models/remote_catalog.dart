class RemotePack {
  final String file;
  final int sizeBytes;
  final String sha256;

  const RemotePack({
    required this.file,
    required this.sizeBytes,
    required this.sha256,
  });

  factory RemotePack.fromJson(Map<String, dynamic> json) => RemotePack(
        file: json['file'] as String,
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        sha256: json['sha256'] as String? ?? '',
      );
}

class RemoteCategory {
  final String id;
  final String name;
  final int count;
  final RemotePack? pack;

  const RemoteCategory({
    required this.id,
    required this.name,
    required this.count,
    this.pack,
  });

  factory RemoteCategory.fromJson(Map<String, dynamic> json) => RemoteCategory(
        id: json['id'] as String,
        name: json['name'] as String,
        count: json['count'] as int? ?? 0,
        pack: json['pack'] == null
            ? null
            : RemotePack.fromJson(json['pack'] as Map<String, dynamic>),
      );
}

class RemoteTile {
  final String id;
  final String name;
  final String category;
  final String file; // path inside the repo, e.g. tiles/floral/star.png
  final String thumbnail;
  final int width;
  final int height;
  final int sizeBytes;
  final String sha256;

  const RemoteTile({
    required this.id,
    required this.name,
    required this.category,
    required this.file,
    required this.thumbnail,
    required this.width,
    required this.height,
    required this.sizeBytes,
    required this.sha256,
  });

  factory RemoteTile.fromJson(Map<String, dynamic> json) => RemoteTile(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String,
        file: json['file'] as String,
        thumbnail: json['thumbnail'] as String? ?? '',
        width: json['width'] as int,
        height: json['height'] as int,
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        sha256: json['sha256'] as String? ?? '',
      );
}

class RemoteCatalog {
  /// The newest metadata.json "schemaVersion" this app understands.
  static const int supportedSchema = 1;

  final int schemaVersion;
  final String baseUrl;
  final String packsBaseUrl;
  final List<RemoteCategory> categories;
  final List<RemoteTile> tiles;

  const RemoteCatalog({
    required this.schemaVersion,
    required this.baseUrl,
    required this.packsBaseUrl,
    required this.categories,
    required this.tiles,
  });

  static String _withSlash(String s) =>
      s.isEmpty || s.endsWith('/') ? s : '$s/';

  factory RemoteCatalog.fromJson(Map<String, dynamic> json) => RemoteCatalog(
        schemaVersion: json['schemaVersion'] as int? ?? 1,
        baseUrl: _withSlash(json['baseUrl'] as String? ?? ''),
        packsBaseUrl: _withSlash(json['packsBaseUrl'] as String? ?? ''),
        categories: (json['categories'] as List<dynamic>? ?? [])
            .map((c) => RemoteCategory.fromJson(c as Map<String, dynamic>))
            .toList(),
        tiles: (json['tiles'] as List<dynamic>? ?? [])
            .map((t) => RemoteTile.fromJson(t as Map<String, dynamic>))
            .toList(),
      );

  Uri fileUrl(RemoteTile tile) => Uri.parse('$baseUrl${tile.file}');

  Uri? thumbnailUrl(RemoteTile tile) =>
      tile.thumbnail.isEmpty ? null : Uri.parse('$baseUrl${tile.thumbnail}');

  Uri packUrl(RemotePack pack) => Uri.parse('$packsBaseUrl${pack.file}');

  List<RemoteTile> tilesIn(String categoryId) =>
      tiles.where((t) => t.category == categoryId).toList();

  RemoteCategory? categoryById(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }
}