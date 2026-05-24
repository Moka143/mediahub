import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:watcher/watcher.dart';

import '../models/local_media_file.dart';

/// Service for scanning local media files from the download folder
class LocalMediaScanner {
  final String downloadPath;
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
      debugPrint('Error scanning directory: $e');
    }

    // Sort by modified date (newest first)
    files.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
    _cachedFiles = files;

    return files;
  }

  /// Get cached files (from last scan)
  List<LocalMediaFile> get cachedFiles => _cachedFiles;

  /// Watch for file changes in the download directory.
  ///
  /// First emission is the initial scan; each subsequent emission is a
  /// rescan triggered by a filesystem event. Previously this used a
  /// broadcast [StreamController] with the initial scan side-channeled in
  /// via `.add()` — which raced against the subscriber: if the controller
  /// emitted before Riverpod's [StreamProvider] subscribed, the initial
  /// emission was lost and the Library tab showed the empty state until
  /// the user hit Refresh. Using an `async*` generator instead, the
  /// initial scan is part of the subscribed stream itself (yielded
  /// *after* the subscriber is in place), so there's nothing to race.
  Stream<List<LocalMediaFile>> watchDirectory() async* {
    yield await scanDirectory();

    final DirectoryWatcher watcher;
    try {
      watcher = DirectoryWatcher(downloadPath);
    } catch (e) {
      debugPrint('Error setting up file watcher: $e');
      return;
    }

    await for (final _ in watcher.events) {
      // Rescan on any file change — not just video files, because
      // deletions often happen at the directory level.
      yield await scanDirectory();
    }
  }

  /// Stop watching the directory.
  ///
  /// No-op — the `async*` generator in [watchDirectory] cleans itself up
  /// when the subscriber cancels (which happens automatically when
  /// [localMediaScannerProvider] is invalidated). Kept for API stability.
  void stopWatching() {}

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
        final seasonCompare = (a.seasonNumber ?? 0).compareTo(
          b.seasonNumber ?? 0,
        );
        if (seasonCompare != 0) return seasonCompare;
        return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
      });
    }

    return grouped;
  }

  /// Get recently downloaded files (last 7 days)
  List<LocalMediaFile> getRecentFiles(
    List<LocalMediaFile> files, {
    int days = 7,
  }) {
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
    final normalizedShowName = showName.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );

    for (final file in files) {
      if (file.seasonNumber == season && file.episodeNumber == episode) {
        if (file.showName != null) {
          final normalizedFileName = file.showName!.toLowerCase().replaceAll(
            RegExp(r'[^a-z0-9]'),
            '',
          );
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
      debugPrint('Error finding subtitles: $e');
    }

    return subtitles;
  }

  /// Dispose resources
  void dispose() {
    stopWatching();
  }
}
