import 'package:flutter/material.dart';

import 'ui/tile_grid_screen.dart';

void main() {
  runApp(const FloorpaperApp());
}

class FloorpaperApp extends StatelessWidget {
  const FloorpaperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Floorpaper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const TileGridScreen(),
    );
  }
}
