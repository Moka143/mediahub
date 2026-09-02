import 'dart:io';

import 'package:watcher/watcher.dart';

import '../models/local_media_file.dart';
import '../utils/platform_utils.dart';
import 'app_logger.dart';

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

    // One unreadable subdirectory must not end the walk.
    //
    // `Directory.list` reports a folder it cannot open as a stream error and
    // then carries on, but an error that reaches `await for` breaks the loop
    // — so a single bad folder used to discard every file after it, with one
    // log line and a half-empty Library to show for it.
    //
    // Windows hits this routinely and macOS almost never does, which is why
    // it went unnoticed: a download folder at a drive root always contains
    // `System Volume Information` and `$RECYCLE.BIN`, neither readable, and
    // OneDrive adds placeholder files that fail to stat until they are
    // hydrated.
    var skipped = 0;
    final entities = directory.list(recursive: true).handleError((Object e) {
      skipped++;
      AppLog.d('[LibraryScan] skipped an unreadable entry: $e');
    }, test: (e) => e is FileSystemException);

    try {
      await for (final entity in entities) {
        if (entity is! File) continue;
        try {
          final mediaFile = await LocalMediaFile.fromFile(entity);
          if (mediaFile != null) files.add(mediaFile);
        } on FileSystemException catch (e) {
          // A file that vanished mid-scan, or one qBittorrent is still
          // writing and has locked — Windows refuses the stat outright.
          skipped++;
          AppLog.d('[LibraryScan] skipped ${entity.path}: $e');
        }
      }
    } catch (e) {
      // Anything the per-entry guards did not cover.
      AppLog.e('[LibraryScan] Error scanning directory: $e');
    }

    if (skipped > 0) {
      AppLog.i(
        '[LibraryScan] ${files.length} file(s) found, $skipped entry/entries '
        'skipped as unreadable',
      );
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
      AppLog.e('[LibraryScan] Error setting up file watcher: $e');
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

  /// Find external subtitle files for a video.
  ///
  /// Uses [basenameOf] rather than splitting on the host separator: a torrent
  /// created on Windows hands back `Show\\S01E01.mkv`, and `path.basename`
  /// on macOS treats the backslash as an ordinary character — so the "file
  /// name" became the whole relative path and no sidecar ever matched it.
  Future<List<String>> findSubtitles(String videoPath) async {
    final subtitles = <String>[];
    final videoDir = File(videoPath).parent;
    final videoName = basenameOf(videoPath);
    final videoBase = videoName.contains('.')
        ? videoName.substring(0, videoName.lastIndexOf('.'))
        : videoName;

    final subtitleExtensions = ['srt', 'ass', 'ssa', 'sub', 'vtt'];

    try {
      await for (final entity in videoDir.list()) {
        if (entity is File) {
          final fileName = basenameOf(entity.path);
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
      AppLog.e('[LibraryScan] Error finding subtitles: $e');
    }

    return subtitles;
  }

  /// Dispose resources
  void dispose() {
    stopWatching();
  }
}
