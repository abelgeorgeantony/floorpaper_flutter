import 'package:flutter/foundation.dart';

import '../models/remote_catalog.dart';
import 'remote_tile_repository.dart';

enum DownloadStatus { running, success, failed }

class DownloadTask {
  final String key;
  final String label;
  double progress;
  DownloadStatus status;
  String? message;

  DownloadTask({
    required this.key,
    required this.label,
    this.progress = 0,
    this.status = DownloadStatus.running,
    this.message,
  });
}

/// Application-wide, persistent download manager.
///
/// Lives above the navigation stack so downloads started from the tile store
/// continue running after the store screen is popped. The store screen
/// observes [instance] via [ChangeNotifier]; the home screen uses
/// pull-to-refresh to reload local state once downloads have landed.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  final RemoteTileRepository _repository = RemoteTileRepository();
  final Map<String, DownloadTask> _tasks = {};
  Set<String> _downloadedIds = {};
  bool _disposed = false;

  RemoteTileRepository get repository => _repository;
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);
  Set<String> get downloadedIds => Set.unmodifiable(_downloadedIds);

  DownloadTask? taskFor(String key) => _tasks[key];

  bool isDownloading(String key) =>
      _tasks[key]?.status == DownloadStatus.running;

  bool isDownloaded(String tileId) => _downloadedIds.contains(tileId);

  Future<void> refreshDownloadedIds() async {
    _downloadedIds = await _repository.store.downloadedIds();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> downloadTile(RemoteCatalog catalog, RemoteTile tile) async {
    if (isDownloading(tile.id)) return;
    _tasks[tile.id] = DownloadTask(key: tile.id, label: tile.name);
    _notify();
    try {
      await _repository.downloadTile(
        catalog,
        tile,
        onProgress: (p) => _updateProgress(tile.id, p),
      );
      final task = _tasks[tile.id];
      if (task != null) {
        task.status = DownloadStatus.success;
        task.progress = 1;
        task.message = '${tile.name} downloaded.';
      }
      await refreshDownloadedIds();
    } catch (e) {
      final task = _tasks[tile.id];
      if (task != null) {
        task.status = DownloadStatus.failed;
        task.message = 'Could not download ${tile.name}: $e';
      }
    }
    _notify();
  }

  Future<void> downloadPack(
      RemoteCatalog catalog, RemoteCategory category) async {
    final key = 'pack:${category.id}';
    if (isDownloading(key)) return;
    _tasks[key] = DownloadTask(key: key, label: category.name);
    _notify();
    try {
      final result = await _repository.downloadPack(
        catalog,
        category,
        onProgress: (p) => _updateProgress(key, p),
      );
      final task = _tasks[key];
      if (task != null) {
        task.status = DownloadStatus.success;
        task.progress = 1;
        if (result.failed.isEmpty) {
          task.message = '${result.saved} tiles added from ${category.name}.';
        } else if (result.saved == 0) {
          task.message =
              'Download failed for ${result.failed.length} tiles. Try again.';
        } else {
          task.message =
              '${result.saved} added, ${result.failed.length} failed.';
        }
      }
      await refreshDownloadedIds();
    } catch (e) {
      final task = _tasks[key];
      if (task != null) {
        task.status = DownloadStatus.failed;
        task.message = 'Could not download ${category.name}: $e';
      }
    }
    _notify();
  }

  void _updateProgress(String key, double progress) {
    final task = _tasks[key];
    if (task == null || task.status != DownloadStatus.running) return;
    if (progress >= 1 || progress - task.progress >= 0.02) {
      task.progress = progress;
      _notify();
    }
  }

  void clearTask(String key) {
    if (_tasks.remove(key) != null) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _repository.dispose();
    super.dispose();
  }
}