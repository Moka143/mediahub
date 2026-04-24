import 'dart:async';
import 'dart:io';

import 'package:watcher/watcher.dart';

import '../models/local_media_file.dart';

/// Service for scanning local media files from the download folder
class LocalMediaScanner {
  final String downloadPath;
  DirectoryWatcher? _watcher;
  StreamController<List<LocalMediaFile>>? _streamController;
  List<LocalMediaFile> _cachedFiles = [];

  LocalMediaScanner(this.downloadPath);

  /// Scan the download directory for video files
  Future<List<LocalMediaFile>> scanDirectory() async {
    final directory = Directory(downloadPath);
    if (!await directory.exists()) {
      return [];
    }

    final files = <LocalMediaFile>[];

    try {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is File) {
          final mediaFile = await LocalMediaFile.fromFile(entity);
          if (mediaFile != null) {
            files.add(mediaFile);
          }
        }
      }
    } catch (e) {
      // Handle permission errors or other issues
      print('Error scanning directory: $e');
    }

    // Sort by modified date (newest first)
    files.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
    _cachedFiles = files;

    return files;
  }

  /// Get cached files (from last scan)
  List<LocalMediaFile> get cachedFiles => _cachedFiles;

  /// Watch for file changes in the download directory
  Stream<List<LocalMediaFile>> watchDirectory() {
    _streamController?.close();
    _streamController = StreamController<List<LocalMediaFile>>.broadcast();

    // Initial scan
    scanDirectory().then((files) {
      _streamController?.add(files);
    });

    // Set up watcher
    try {
      _watcher = DirectoryWatcher(downloadPath);
      _watcher!.events.listen((event) async {
        // Rescan on any file change — not just video files, because
        // deletions often happen at the directory level
        final files = await scanDirectory();
        _streamController?.add(files);
      });
    } catch (e) {
      print('Error setting up file watcher: $e');
    }

    return _streamController!.stream;
  }

  /// Check if a path is a video file
  bool _isVideoFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    return videoExtensions.contains(ext);
  }

  /// Stop watching directory
  void stopWatching() {
    _streamController?.close();
    _streamController = null;
    _watcher = null;
  }

  /// Get files grouped by show name
  Map<String, List<LocalMediaFile>> groupByShow(List<LocalMediaFile> files) {
    final grouped = <String, List<LocalMediaFile>>{};

    for (final file in files) {
      final showName = file.showName ?? 'Unknown';
      grouped.putIfAbsent(showName, () => []);
      grouped[showName]!.add(file);
    }

    // Sort episodes within each show
    for (final showFiles in grouped.values) {
      showFiles.sort((a, b) {
        final seasonCompare = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
        if (seasonCompare != 0) return seasonCompare;
        return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
      });
    }

    return grouped;
  }

  /// Get recently downloaded files (last 7 days)
  List<LocalMediaFile> getRecentFiles(List<LocalMediaFile> files, {int days = 7}) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return files.where((f) => f.modifiedDate.isAfter(cutoff)).toList();
  }

  /// Find matching file for a specific episode
  LocalMediaFile? findEpisodeFile(
    List<LocalMediaFile> files, {
    required String showName,
    required int season,
    required int episode,
  }) {
    final normalizedShowName = showName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

    for (final file in files) {
      if (file.seasonNumber == season && file.episodeNumber == episode) {
        if (file.showName != null) {
          final normalizedFileName =
              file.showName!.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          // Check for partial match (handles variations in show names)
          if (normalizedFileName.contains(normalizedShowName) ||
              normalizedShowName.contains(normalizedFileName)) {
            return file;
          }
        }
      }
    }
    return null;
  }

  /// Find external subtitle files for a video
  Future<List<String>> findSubtitles(String videoPath) async {
    final subtitles = <String>[];
    final videoDir = File(videoPath).parent;
    final videoName = videoPath.split('/').last.split('\\').last;
    final videoBase = videoName.contains('.')
        ? videoName.substring(0, videoName.lastIndexOf('.'))
        : videoName;

    final subtitleExtensions = ['srt', 'ass', 'ssa', 'sub', 'vtt'];

    try {
      await for (final entity in videoDir.list()) {
        if (entity is File) {
          final fileName = entity.path.split('/').last.split('\\').last;
          final ext = fileName.split('.').last.toLowerCase();

          if (subtitleExtensions.contains(ext)) {
            // Check if subtitle matches video name
            if (fileName.toLowerCase().startsWith(videoBase.toLowerCase())) {
              subtitles.add(entity.path);
            }
          }
        }
      }
    } catch (e) {
      print('Error finding subtitles: $e');
    }

    return subtitles;
  }

  /// Dispose resources
  void dispose() {
    stopWatching();
  }
}
