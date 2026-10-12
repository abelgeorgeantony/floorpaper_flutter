import 'package:flutter/services.dart';

import '../models/wallpaper_target.dart';
import '../models/screen_info.dart';

class WallpaperService {
  static const MethodChannel _channel =
      MethodChannel('floorpaper/wallpaper');

    Future<ScreenInfo> getScreenInfo() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getWallpaperInfo',
    );
    if (result == null) throw StateError('Could not read screen info.');

    int read(String key) {
      final value = result[key];
      if (value is! int) throw StateError('Invalid value for $key.');
      return value;
    }

    return ScreenInfo(
      screenWidth: read('screenWidth'),
      screenHeight: read('screenHeight'),
      suggestedWidth: read('suggestedWidth'),
      suggestedHeight: read('suggestedHeight'),
    );
  }

  Future<void> setWallpaperFromFile({
    required String filePath,
    required WallpaperTarget target,
    int? hintWidth,
    int? hintHeight,
  }) async {
    await _channel.invokeMethod<void>('setWallpaperFromFile', {
      'path': filePath,
      'target': target.platformName,
      'hintWidth': hintWidth,
      'hintHeight': hintHeight,
    });
  }
}