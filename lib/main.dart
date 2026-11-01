import 'dart:ui';

import 'package:flutter/material.dart';

import 'ui/theme/app_theme.dart';
import 'ui/tile_grid_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Global Flutter-framework errors (widget build, layout, paint).
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    // TODO(prod): forward to your crash reporter (Sentry, Crashlytics, …)
    //   Sentry.captureException(details.exception, stackTrace: details.stack);
  };

  // Errors outside the Flutter framework (async, isolates, platform).
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    // TODO(prod): forward to your crash reporter
    debugPrint('Uncaught platform error: $error\n$stack');
    return true;
  };

  runApp(const FloorpaperApp());
}

class FloorpaperApp extends StatelessWidget {
  const FloorpaperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Floorpaper',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(Brightness.dark),
      darkTheme: AppTheme.build(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: const TileGridScreen(),
    );
  }
}