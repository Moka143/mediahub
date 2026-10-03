import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../models/local_media_file.dart';
import '../utils/media_names.dart';
import '../utils/platform_utils.dart';
import 'app_logger.dart';

/// Service for scanning local media files from the download folder
class LocalMediaScanner {
  final String downloadPath;

  LocalMediaScanner(this.downloadPath);

  /// How long the folder has to stay quiet before a rescan.
  ///
  /// The library folder is the engine's save path, so an active download
  /// produces a stream of filesystem events. Each one used to start a full
  /// recursive list-and-stat of the whole library, back to back for as long
  /// as anything downloaded.
  static const Duration rescanQuietPeriod = Duration(seconds: 2);

  /// The longest a burst of events can hold a rescan off, so a long download
  /// does not hide a new file that landed next to it until it finishes.
  static const Duration rescanMaxWait = Duration(seconds: 15);

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
    return files;
  }

  /// Whether a filesystem event can change what the library shows.
  ///
  /// A removal matters when it takes away something the library lists — the
  /// file itself, or a folder holding it. Otherwise only video files can
  /// matter: subtitles, `.part` files, artwork and engine state come and go
  /// constantly in a download folder. And a video the last scan already
  /// listed changing size is a download in progress, not a new entry.
  @visibleForTesting
  static bool isLibraryEvent(WatchEvent event, Set<String> listed) {
    final path = event.path;
    if (event.type == ChangeType.REMOVE) {
      return listed.contains(path) || listed.any((l) => p.isWithin(path, l));
    }
    final name = basenameOf(path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return false;
    final ext = name.substring(dot + 1).toLowerCase();
    if (!videoExtensions.contains(ext)) return false;
    return !(event.type == ChangeType.MODIFY && listed.contains(path));
  }

  /// Watch for file changes in the download directory.
  ///
  /// First emission is the initial scan; each subsequent emission is a
  /// rescan triggered by a burst of relevant filesystem events — coalesced
  /// (see [rescanQuietPeriod]) and filtered ([isLibraryEvent]).
  ///
  /// An `async*` generator rather than a broadcast controller with the
  /// initial scan side-channeled in: that raced the subscriber, and when it
  /// emitted before Riverpod's StreamProvider subscribed, the Library tab
  /// showed the empty state until the user hit Refresh. Here the initial
  /// scan is part of the subscribed stream itself, and the watcher stops
  /// when the subscriber cancels.
  Stream<List<LocalMediaFile>> watchDirectory() async* {
    var files = await scanDirectory();
    yield files;

    final DirectoryWatcher watcher;
    try {
      watcher = DirectoryWatcher(downloadPath);
    } catch (e) {
      AppLog.e('[LibraryScan] Error setting up file watcher: $e');
      return;
    }

    var listed = {for (final f in files) f.path};
    final bursts = coalesceBursts(
      watcher.events.where((e) => isLibraryEvent(e, listed)),
      quiet: rescanQuietPeriod,
      maxWait: rescanMaxWait,
    );
    await for (final _ in bursts) {
      files = await scanDirectory();
      listed = {for (final f in files) f.path};
      yield files;
    }
  }

  /// Find the library file for [season]x[episode] of [showName].
  ///
  /// The show must be the *same* show, not one whose name contains the
  /// other: "You" S01E01 used to return `Young.Sheldon.S01E01`, and "Dark"
  /// returned `Dark.Matter.S01E01` — the details page then played the wrong
  /// series. When both sides know the TMDB [showId], that decides instead.
  LocalMediaFile? findEpisodeFile(
    List<LocalMediaFile> files, {
    required String showName,
    required int season,
    required int episode,
    int? showId,
  }) {
    for (final file in files) {
      if (file.seasonNumber != season || file.episodeNumber != episode) {
        continue;
      }
      final fileShowId = file.showId;
      if (showId != null && fileShowId != null) {
        if (fileShowId == showId) return file;
        continue;
      }
      final fileShow = file.showName;
      if (fileShow != null && titlesMatch(fileShow, showName)) return file;
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
}

/// One event per burst of [source] events: emitted once [source] has been
/// quiet for [quiet], or [maxWait] after the burst began, whichever is
/// first. A burst still open when [source] ends is flushed.
@visibleForTesting
Stream<void> coalesceBursts<T>(
  Stream<T> source, {
  required Duration quiet,
  required Duration maxWait,
}) {
  StreamSubscription<T>? subscription;
  Timer? quietTimer;
  Timer? maxTimer;
  late final StreamController<void> controller;

  void cancelTimers() {
    quietTimer?.cancel();
    maxTimer?.cancel();
    quietTimer = null;
    maxTimer = null;
  }

  void fire() {
    cancelTimers();
    if (!controller.isClosed) controller.add(null);
  }

  controller = StreamController<void>(
    onListen: () {
      subscription = source.listen(
        (_) {
          quietTimer?.cancel();
          quietTimer = Timer(quiet, fire);
          maxTimer ??= Timer(maxWait, fire);
        },
        onError: controller.addError,
        onDone: () {
          if (quietTimer != null) fire();
          unawaited(controller.close());
        },
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      cancelTimers();
      await subscription?.cancel();
    },
  );
  return controller.stream;
}
