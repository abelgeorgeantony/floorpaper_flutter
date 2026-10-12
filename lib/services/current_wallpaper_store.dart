import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/current_wallpaper.dart';

class CurrentWallpaperStore {
  static const String _fileName = 'current_wallpaper.json';

  Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/$_fileName');
  }

  Future<void> save(CurrentWallpaper wallpaper) async {
    final file = await _file();

    await file.parent.create(recursive: true);

    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(wallpaper.toJson()),
      flush: true,
    );

    await tmp.rename(file.path);
  }

  Future<CurrentWallpaper?> load() async {
    try {
      final file = await _file();

      if (!await file.exists()) return null;

      final decoded = jsonDecode(await file.readAsString());
      return CurrentWallpaper.fromJson(decoded as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}