import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';
import 'package:mediahub/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end over the real provider graph: a directory on disk → the
/// scanner → the library providers → the watched index → what the UI would
/// actually offer to play.
///
/// Every unit test in this repo exercises one function. Three of the bugs
/// found by running the app were invisible to all of them *and* to
/// `flutter analyze`, because each was an interaction: a zero-byte file that
/// every individual check called valid, a watched mark that each store
/// answered differently about, a Continue Watching row filtered against the
/// wrong source. Those only appear once the pieces are wired together.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mediahub_pipeline_');
  });

  tearDown(() async {
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {
      // A directory watcher may still hold it briefly; harmless in a temp dir.
    }
  });

  /// Write a file of [bytes] length inside the fake library.
  Future<File> makeFile(String name, {required int bytes}) async {
    final f = File('${tempDir.path}${Platform.pathSeparator}$name');
    await f.create(recursive: true);
    if (bytes > 0) await f.writeAsBytes(List<int>.filled(bytes, 0x1a));
    return f;
  }

  /// Read the library, holding a subscription open while it loads.
  ///
  /// Riverpod 3 disposes providers nothing is listening to, and a bare
  /// `container.read(...)` creates no lasting listener — so the scanner's
  /// stream was being torn down mid-scan and the future never completed.
  Future<List<LocalMediaFile>> library(ProviderContainer container) async {
    final sub = container.listen(localMediaFilesProvider, (_, _) {});
    addTearDown(sub.close);
    return container.read(localMediaFilesProvider.future);
  }

  /// Wait until [condition] holds.
  ///
  /// Riverpod keeps a StreamProvider's previous value across a rebuild — by
  /// design, so the UI doesn't flicker while a rescan is in flight. That
  /// means awaiting the future after an invalidate resolves against the
  /// *stale* list, and a rescan's result has to be waited for explicitly.
  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition still false after ${timeout.inSeconds}s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<ProviderContainer> makeContainer({
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'default_save_path': tempDir.path}),
      ...prefs,
    });
    final sp = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(sp)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('scanner → library providers', () {
    test('a real episode reaches the library with parsed metadata', () async {
      await makeFile(
        'Severance.S02E01.1080p.WEB-DL.mkv',
        bytes: 2 * 1024 * 1024,
      );
      final container = await makeContainer();

      final files = await library(container);

      expect(files, hasLength(1));
      expect(files.single.showName, isNotNull);
      expect(files.single.seasonNumber, 2);
      expect(files.single.episodeNumber, 1);
    });

    test('a zero-byte file never enters the library', () async {
      // The exact shape that broke playback: several public packs ship
      // zero-byte placeholders, and qBittorrent calls them 100% complete
      // because 0 of 0 bytes is 100%. Nothing downstream can tell the
      // difference, so the scanner has to.
      await makeFile('Severance.S02E02.1080p.WEB-DL.mkv', bytes: 0);
      await makeFile(
        'Severance.S02E03.1080p.WEB-DL.mkv',
        bytes: 2 * 1024 * 1024,
      );
      final container = await makeContainer();

      final files = await library(container);

      expect(files, hasLength(1));
      expect(files.single.episodeNumber, 3);
    });

    test('a sub-threshold sample clip is excluded too', () async {
      await makeFile('sample.mkv', bytes: 4096);
      final container = await makeContainer();

      expect(await library(container), isEmpty);
    });

    test('non-video files are ignored', () async {
      await makeFile('readme.txt', bytes: 2 * 1024 * 1024);
      await makeFile('cover.jpg', bytes: 2 * 1024 * 1024);
      final container = await makeContainer();

      expect(await library(container), isEmpty);
    });
  });

  group('library → Continue Watching', () {
    /// A progress entry for [path], [ratio] of the way through.
    String progressJson(String path, double ratio, {bool completed = false}) {
      return jsonEncode([
        WatchProgress(
          fileHash: WatchProgress.generateHash(path),
          filePath: path,
          showName: 'Severance',
          seasonNumber: 2,
          episodeNumber: 1,
          episodeCode: 'S02E01',
          position: Duration(seconds: (3600 * ratio).round()),
          duration: const Duration(seconds: 3600),
          lastWatched: DateTime(2026, 1, 1),
          isCompleted: completed,
        ).toJson(),
      ]);
    }

    test('a part-watched file in the library shows up', () async {
      final f = await makeFile('Severance.S02E01.mkv', bytes: 2 * 1024 * 1024);
      final container = await makeContainer(
        prefs: {'watch_progress': progressJson(f.path, 0.4)},
      );
      await library(container);

      final cw = container.read(continueWatchingProvider);

      expect(cw, hasLength(1));
      expect(cw.single.filePath, f.path);
    });

    test('progress written after the scan still reaches the file', () async {
      // The join between scanned files and watch progress used to live inside
      // `localMediaStreamProvider`. That made every progress write — one per
      // 10 s of playback — cancel the directory watcher and re-run a full
      // recursive scan. The join now happens downstream in
      // `localMediaFilesProvider`; this pins the behaviour that move had to
      // preserve, which is that a *later* write still lands on the file.
      final f = await makeFile('Severance.S02E01.mkv', bytes: 2 * 1024 * 1024);
      final container = await makeContainer();

      final before = await library(container);
      expect(before.single.progress, isNull);

      await container
          .read(watchProgressProvider.notifier)
          .createProgress(
            filePath: f.path,
            showName: 'Severance',
            seasonNumber: 2,
            episodeNumber: 1,
            position: const Duration(seconds: 1440),
            duration: const Duration(seconds: 3600),
          );

      await waitUntil(
        () =>
            container.read(localMediaFilesProvider).value?.single.progress !=
            null,
      );
      final after = container.read(localMediaFilesProvider).value!;
      expect(after.single.watchProgress, closeTo(0.4, 0.01));
    });

    test('a deleted file drops out of Continue Watching', () async {
      // The entry survives — the watched history is deliberately kept — but
      // it must not be offered for playback.
      final f = await makeFile('Severance.S02E01.mkv', bytes: 2 * 1024 * 1024);
      final container = await makeContainer(
        prefs: {'watch_progress': progressJson(f.path, 0.4)},
      );
      await library(container);
      expect(container.read(continueWatchingProvider), hasLength(1));

      await f.delete();
      container.invalidate(localMediaScannerProvider);
      container.invalidate(localMediaStreamProvider);
      container.invalidate(localMediaFilesProvider);
      await waitUntil(
        () => container.read(libraryPathsProvider)?.isEmpty ?? false,
      );

      expect(container.read(continueWatchingProvider), isEmpty);
    });

    test('a barely-started file is not Continue Watching', () async {
      final f = await makeFile('Severance.S02E01.mkv', bytes: 2 * 1024 * 1024);
      final container = await makeContainer(
        prefs: {'watch_progress': progressJson(f.path, 0.01)},
      );
      await library(container);

      expect(container.read(continueWatchingProvider), isEmpty);
    });

    test('90%+ without the completed flag is not Continue Watching', () async {
      final f = await makeFile('Severance.S02E01.mkv', bytes: 2 * 1024 * 1024);
      final container = await makeContainer(
        prefs: {'watch_progress': progressJson(f.path, 0.95)},
      );
      await library(container);

      expect(container.read(continueWatchingProvider), isEmpty);
      expect(
        container
            .read(watchedIndexProvider)
            .isEpisodeWatched(
              showId: 95396,
              season: 2,
              episode: 1,
              showName: 'Severance',
            ),
        isTrue,
      );
      final files = container.read(localMediaFilesProvider).value ?? [];
      expect(files, isNotEmpty);
      expect(files.first.isWatched, isTrue);
    });

    test('a finished file is not Continue Watching, but is watched', () async {
      final f = await makeFile('Severance.S02E01.mkv', bytes: 2 * 1024 * 1024);
      final container = await makeContainer(
        prefs: {'watch_progress': progressJson(f.path, 0.95, completed: true)},
      );
      await library(container);

      expect(container.read(continueWatchingProvider), isEmpty);
      expect(
        container
            .read(watchedIndexProvider)
            .isEpisodeWatched(
              showId: 95396,
              season: 2,
              episode: 1,
              showName: 'Severance',
            ),
        isTrue,
      );
    });
  });

  group('watched state survives the file', () {
    test(
      'the mark outlives deletion — the regression chased 3 times',
      () async {
        final f = await makeFile(
          'Severance.S02E01.mkv',
          bytes: 2 * 1024 * 1024,
        );
        final container = await makeContainer(
          prefs: {
            'watch_progress': jsonEncode([
              WatchProgress(
                fileHash: WatchProgress.generateHash(f.path),
                filePath: f.path,
                showName: 'Severance',
                seasonNumber: 2,
                episodeNumber: 1,
                episodeCode: 'S02E01',
                position: Duration.zero,
                duration: Duration.zero,
                lastWatched: DateTime(2026, 1, 1),
                isCompleted: true,
              ).toJson(),
            ]),
          },
        );
        await library(container);

        await f.delete();
        container.invalidate(localMediaScannerProvider);
        container.invalidate(localMediaStreamProvider);
        container.invalidate(localMediaFilesProvider);
        await waitUntil(
          () => container.read(libraryPathsProvider)?.isEmpty ?? false,
        );

        // Gone from anything offering playback...
        expect(container.read(continueWatchingProvider), isEmpty);
        expect(container.read(libraryPathsProvider), isEmpty);
        // ...but still watched, which is what the episodes drawer reads.
        expect(
          container
              .read(watchedIndexProvider)
              .isEpisodeWatched(
                showId: 95396,
                season: 2,
                episode: 1,
                showName: 'Severance',
              ),
          isTrue,
        );
      },
    );

    test('legacy manual-watched marks are migrated, not lost', () async {
      final container = await makeContainer(
        prefs: {
          'manual_watched_episodes': jsonEncode({
            'watched_episodes': {
              '95396': ['S01E01', 'S01E02'],
            },
          }),
        },
      );
      final notifier = container.read(watchProgressProvider.notifier);

      // Same conversion migrateManualWatchedMarks performs.
      for (final mark in parseLegacyEpisodeMarks(
        container
            .read(sharedPreferencesProvider)
            .getString('manual_watched_episodes')!,
      )) {
        await notifier.markCompleted(
          'manual:watched:${mark.showId}/${mark.season}/${mark.episode}',
          showId: mark.showId,
          seasonNumber: mark.season,
          episodeNumber: mark.episode,
        );
      }

      final index = container.read(watchedIndexProvider);
      expect(
        index.isEpisodeWatched(showId: 95396, season: 1, episode: 1),
        isTrue,
      );
      expect(
        index.isEpisodeWatched(showId: 95396, season: 1, episode: 2),
        isTrue,
      );
      // Synthetic entries carry a mark but are never playable.
      expect(container.read(continueWatchingProvider), isEmpty);
    });
  });

  group('cross-platform paths', () {
    test('basenameOf handles both separators, wherever we run', () async {
      expect(
        basenameOf(r'C:\Users\me\Downloads\Show.S01E01.mkv'),
        'Show.S01E01.mkv',
      );
      expect(
        basenameOf('/Users/me/Downloads/Show.S01E01.mkv'),
        'Show.S01E01.mkv',
      );
      expect(basenameOf(r'Season 01\Episode.mkv'), 'Episode.mkv');
      expect(basenameOf('Show.S01E01.mkv'), 'Show.S01E01.mkv');
      expect(basenameOf(''), '');
    });

    test('a Windows-style progress path still yields a usable name', () async {
      // On Windows this used to keep the whole path as the "file name",
      // which then poisoned the TMDB movie lookup in the watched-sync.
      const windows = r'C:\Users\me\Downloads\Arrival.2016.1080p.mkv';
      expect(basenameOf(windows), 'Arrival.2016.1080p.mkv');
    });
  });

  group('LocalMediaFile.fromFile', () {
    test('rejects the empty file, accepts the real one', () async {
      final empty = await makeFile('Empty.S01E01.mkv', bytes: 0);
      final real = await makeFile('Real.S01E01.mkv', bytes: 2 * 1024 * 1024);

      expect(await LocalMediaFile.fromFile(empty), isNull);
      expect(await LocalMediaFile.fromFile(real), isNotNull);
    });
  });
}
