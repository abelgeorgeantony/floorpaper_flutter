import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/current_wallpaper.dart';
import '../models/wallpaper_target.dart';

class CurrentWallpaperStore {
  static const String _legacyFileName = 'current_wallpaper.json';

  Future<File> _fileFor(WallpaperTarget target) async {
    final support = await getApplicationSupportDirectory();
    return File(
      '${support.path}/current_wallpaper_${target.platformName}.json',
    );
  }

  Future<File> _legacyFile() async {
    final support = await getApplicationSupportDirectory();
    return File('${support.path}/$_legacyFileName');
  }

  Future<void> save(CurrentWallpaper wallpaper) async {
    final file = await _fileFor(wallpaper.target);

    await file.parent.create(recursive: true);

    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(wallpaper.toJson()),
      flush: true,
    );

    await tmp.rename(file.path);
  }

  Future<CurrentWallpaper?> loadFor(WallpaperTarget target) async {
    try {
      final file = await _fileFor(target);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        return CurrentWallpaper.fromJson(decoded as Map<String, dynamic>);
      }

      // Legacy single-file record (pre home/lock split). Surfaced for the
      // target it was actually applied to — or for both, if it was applied
      // to both — so upgrading users keep seeing their wallpaper.
      final legacy = await _legacyFile();
      if (!await legacy.exists()) return null;

      final decoded = jsonDecode(await legacy.readAsString());
      final record =
          CurrentWallpaper.fromJson(decoded as Map<String, dynamic>);

      if (record.target == target || record.target == WallpaperTarget.both) {
        return record;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Whichever record was saved most recently. Kept for compatibility with
  /// call sites that don't care about a specific target.
  Future<CurrentWallpaper?> load() async {
    return await loadFor(WallpaperTarget.home) ??
        await loadFor(WallpaperTarget.lock);
  }
}