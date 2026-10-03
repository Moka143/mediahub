import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/movie.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/providers/tmdb_account_provider.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';
import 'package:mediahub/services/tmdb_account_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/tmdb_watched_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Behavioural tests for [WatchProgressNotifier].
///
/// This notifier is the app's watched-state source of truth and one of the
/// most-edited files in the repo, but every test that touched watch progress
/// went through `WatchedIndex` — the pure read model — so the *mutations*
/// were unguarded. The cases below pin the rules the surrounding comments
/// say were learned the hard way: the 90% promotion, the synthetic upsert
/// that must not appear in Continue Watching, and the stale-entry sweep that
/// must not destroy a watched mark when a file is deleted.
///
/// TMDB push is inert here: [_container] never signs in, so
/// `_pushWatchedToTmdb` returns at its `isTmdbSignedInProvider` guard and no
/// test needs a fake account service.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const key = 'watch_progress';

  /// A progress row with only the fields a given test cares about.
  WatchProgress entry({
    required String path,
    bool isCompleted = false,
    String? showName,
    int? showId,
    int? season,
    int? episode,
    int? movieId,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  }) {
    return WatchProgress(
      fileHash: WatchProgress.generateHash(path),
      filePath: path,
      showName: showName,
      showId: showId,
      seasonNumber: season,
      episodeNumber: episode,
      movieId: movieId,
      position: position,
      duration: duration,
      lastWatched: DateTime(2026, 1, 1),
      isCompleted: isCompleted,
    );
  }

  /// A container whose prefs start out holding [seed].
  Future<ProviderContainer> containerWith(List<WatchProgress> seed) async {
    SharedPreferences.setMockInitialValues({
      if (seed.isNotEmpty) key: jsonEncode([for (final p in seed) p.toJson()]),
    });
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Read the notifier while holding a listener open, so Riverpod 3 does not
  /// dispose the provider out from under an in-flight mutation.
  WatchProgressNotifier notifierOf(ProviderContainer c) {
    final sub = c.listen(watchProgressProvider, (_, _) {});
    addTearDown(sub.close);
    return c.read(watchProgressProvider.notifier);
  }

  /// Overwrite the store with a value the notifier would never produce, so a
  /// later [wroteSinceProbe] can tell "saved nothing" apart from "saved the
  /// same thing". Seeded prefs are non-empty, so an `isEmpty` check cannot.
  const probe = '__probe__';
  void arm(ProviderContainer c) {
    // In memory at once; the disk write is irrelevant to the probe.
    unawaited(c.read(sharedPreferencesProvider).setString(key, probe));
  }

  bool wroteSinceProbe(ProviderContainer c) =>
      c.read(sharedPreferencesProvider).getString(key) != probe;

  /// What is actually on disk, independent of in-memory state.
  List<Map<String, dynamic>> persisted(ProviderContainer c) {
    final raw = c.read(sharedPreferencesProvider).getString(key);
    if (raw == null) return [];
    return [
      for (final e in jsonDecode(raw) as List<dynamic>)
        e as Map<String, dynamic>,
    ];
  }

  group('load', () {
    test('an empty store yields an empty map, not a crash', () async {
      final c = await containerWith([]);
      expect(c.read(watchProgressProvider), isEmpty);
    });

    test(
      'corrupt JSON degrades to empty rather than taking down startup',
      () async {
        SharedPreferences.setMockInitialValues({key: 'not json at all'});
        final prefs = await SharedPreferences.getInstance();
        final c = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );
        addTearDown(c.dispose);

        expect(c.read(watchProgressProvider), isEmpty);
      },
    );

    test(
      'an entry past the threshold is promoted to completed on load',
      () async {
        final c = await containerWith([
          entry(
            path: '/x/s01e01.mkv',
            position: const Duration(minutes: 95),
            duration: const Duration(minutes: 100),
          ),
        ]);

        final loaded = c.read(watchProgressProvider).values.single;
        expect(loaded.isCompleted, isTrue);
      },
    );

    test(
      'a promotion on load is written back, not just held in memory',
      () async {
        final c = await containerWith([
          entry(
            path: '/x/s01e01.mkv',
            position: const Duration(minutes: 95),
            duration: const Duration(minutes: 100),
          ),
        ]);
        notifierOf(c);

        // The promotion is persisted from a microtask so `build()` stays sync.
        await Future<void>.delayed(Duration.zero);

        expect(persisted(c).single['is_completed'], isTrue);
      },
    );

    test('an entry below the threshold is left alone', () async {
      final c = await containerWith([
        entry(
          path: '/x/s01e01.mkv',
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 100),
        ),
      ]);

      expect(c.read(watchProgressProvider).values.single.isCompleted, isFalse);
    });
  });

  group('updateProgress', () {
    test('crossing 90% flips isCompleted', () async {
      final c = await containerWith([]);
      await notifierOf(c).updateProgress(
        entry(
          path: '/x/a.mkv',
          position: const Duration(minutes: 91),
          duration: const Duration(minutes: 100),
        ),
      );

      expect(c.read(watchProgressProvider).values.single.isCompleted, isTrue);
    });

    test('staying below 90% does not', () async {
      final c = await containerWith([]);
      await notifierOf(c).updateProgress(
        entry(
          path: '/x/a.mkv',
          position: const Duration(minutes: 50),
          duration: const Duration(minutes: 100),
        ),
      );

      expect(c.read(watchProgressProvider).values.single.isCompleted, isFalse);
    });

    test('the row reaches disk', () async {
      final c = await containerWith([]);
      await notifierOf(c).updateProgress(entry(path: '/x/a.mkv'));

      expect(persisted(c), hasLength(1));
      expect(persisted(c).single['file_path'], '/x/a.mkv');
    });
  });

  group('markCompleted', () {
    test('upserts a synthetic row when the file was never opened', () async {
      final c = await containerWith([]);
      await notifierOf(c).markCompleted(
        '/x/never-opened.mkv',
        showName: 'Lioness',
        seasonNumber: 2,
        episodeNumber: 1,
      );

      final row = c.read(watchProgressProvider).values.single;
      expect(row.isCompleted, isTrue);
      expect(row.showName, 'Lioness');
      expect(row.episodeCode, 'S02E01');
    });

    test(
      'a synthetic row has zero progress, so Continue Watching skips it',
      () async {
        final c = await containerWith([]);
        await notifierOf(c).markCompleted('/x/never-opened.mkv');

        final row = c.read(watchProgressProvider).values.single;
        expect(row.duration, Duration.zero);
        expect(row.progress, 0.0);
      },
    );

    test('merges a newly-resolved movieId onto an existing row', () async {
      final c = await containerWith([entry(path: '/x/dune.mkv')]);
      await notifierOf(c).markCompleted('/x/dune.mkv', movieId: 693134);

      final row = c.read(watchProgressProvider).values.single;
      expect(row.movieId, 693134);
      expect(row.isCompleted, isTrue);
    });

    test('does not erase an id the row already had', () async {
      final c = await containerWith([
        entry(path: '/x/dune.mkv', movieId: 693134),
      ]);
      await notifierOf(c).markCompleted('/x/dune.mkv');

      expect(c.read(watchProgressProvider).values.single.movieId, 693134);
    });
  });

  group('markNotCompleted', () {
    test('clears the flag and rewinds to the start', () async {
      final c = await containerWith([
        entry(
          path: '/x/a.mkv',
          isCompleted: true,
          position: const Duration(minutes: 95),
          duration: const Duration(minutes: 100),
        ),
      ]);
      await notifierOf(c).markNotCompleted('/x/a.mkv');

      final row = c.read(watchProgressProvider).values.single;
      expect(row.isCompleted, isFalse);
      expect(row.position, Duration.zero);
    });

    test('is a no-op for a path with no row', () async {
      final c = await containerWith([entry(path: '/x/a.mkv')]);
      await notifierOf(c).markNotCompleted('/x/absent.mkv');

      expect(c.read(watchProgressProvider), hasLength(1));
    });
  });

  group('clearProgress', () {
    test('removes only the named row', () async {
      final c = await containerWith([
        entry(path: '/x/a.mkv'),
        entry(path: '/x/b.mkv'),
      ]);
      await notifierOf(c).clearProgress('/x/a.mkv');

      final paths = c.read(watchProgressProvider).values.map((p) => p.filePath);
      expect(paths, ['/x/b.mkv']);
      expect(persisted(c), hasLength(1));
    });
  });

  group('attachShowId', () {
    test('persists an id resolved during playback', () async {
      final c = await containerWith([
        entry(path: '/x/a.mkv', season: 2, episode: 1),
      ]);
      await notifierOf(c).attachShowId('/x/a.mkv', 95396);

      expect(c.read(watchProgressProvider).values.single.showId, 95396);
    });

    test('is a no-op when the id already matches', () async {
      final c = await containerWith([entry(path: '/x/a.mkv', showId: 95396)]);
      final n = notifierOf(c);
      arm(c);
      await n.attachShowId('/x/a.mkv', 95396);

      expect(wroteSinceProbe(c), isFalse, reason: 'no change, so no save');
    });

    test('is a no-op for an unknown path', () async {
      final c = await containerWith([entry(path: '/x/a.mkv')]);
      await notifierOf(c).attachShowId('/x/absent.mkv', 1);

      expect(c.read(watchProgressProvider).values.single.showId, isNull);
    });
  });

  group('cleanupStaleEntries', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('mediahub_wp_');
    });

    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    test('keeps a row whose file is still on disk', () async {
      final f = File('${temp.path}${Platform.pathSeparator}real.mkv');
      await f.writeAsString('x');

      final c = await containerWith([entry(path: f.path)]);
      await notifierOf(c).cleanupStaleEntries();

      expect(c.read(watchProgressProvider), hasLength(1));
    });

    test('drops an unwatched row whose file is gone', () async {
      final c = await containerWith([
        entry(path: '${temp.path}${Platform.pathSeparator}gone.mkv'),
      ]);
      await notifierOf(c).cleanupStaleEntries();

      expect(c.read(watchProgressProvider), isEmpty);
    });

    test(
      'keeps a watched row whose file is gone — the tag outlives the file',
      () async {
        final c = await containerWith([
          entry(
            path: '${temp.path}${Platform.pathSeparator}gone.mkv',
            isCompleted: true,
          ),
        ]);
        await notifierOf(c).cleanupStaleEntries();

        expect(c.read(watchProgressProvider), hasLength(1));
      },
    );

    test(
      'promotes a 90%+ row whose file is gone instead of discarding it',
      () async {
        final c = await containerWith([
          entry(
            path: '${temp.path}${Platform.pathSeparator}gone.mkv',
            position: const Duration(minutes: 95),
            duration: const Duration(minutes: 100),
          ),
        ]);
        // The load path already promotes this one; the sweep must not undo it.
        await notifierOf(c).cleanupStaleEntries();

        final rows = c.read(watchProgressProvider).values;
        expect(rows, hasLength(1));
        expect(rows.single.isCompleted, isTrue);
      },
    );

    test('never touches a synthetic path, which has no file to stat', () async {
      final synthetic = '${WatchProgress.syntheticPathPrefixes.first}500/1/2';
      final c = await containerWith([
        entry(path: synthetic, isCompleted: true),
      ]);
      await notifierOf(c).cleanupStaleEntries();

      expect(c.read(watchProgressProvider), hasLength(1));
    });

    test('writes nothing when no row changed', () async {
      final f = File('${temp.path}${Platform.pathSeparator}real.mkv');
      await f.writeAsString('x');

      final c = await containerWith([entry(path: f.path)]);
      final n = notifierOf(c);
      arm(c);
      await n.cleanupStaleEntries();

      expect(
        wroteSinceProbe(c),
        isFalse,
        reason: 'an unchanged sweep must not save',
      );
    });
  });

  group('one bad row', () {
    test('costs only itself, and is kept aside', () async {
      // Any decode error used to load the whole history as empty — and the
      // next playback tick, within ten seconds, saved that over it.
      final good = entry(path: '/x/a.mkv', isCompleted: true).toJson();
      final raw = jsonEncode([
        good,
        {'file_path': 42}, // unreadable
      ]);
      SharedPreferences.setMockInitialValues({key: raw});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);

      expect(c.read(watchProgressProvider), hasLength(1));
      expect(prefs.getString('$key.corrupt'), raw);
    });
  });

  group('TMDB push bookkeeping', () {
    test('the pending flag survives a round trip', () async {
      final c = await containerWith([]);
      await notifierOf(c).markCompleted('/x/a.mkv', tmdbPushPending: true);

      expect(persisted(c).single['tmdb_push_pending'], isTrue);
      final row = c.read(watchProgressProvider).values.single;
      expect(row.tmdbPushPending, isTrue);
      expect(row.followsRemoteUnwatch, isFalse);
    });

    test('a push settles only the state that was pushed', () async {
      final c = await containerWith([]);
      final n = notifierOf(c);
      await n.markCompleted('/x/a.mkv', tmdbPushPending: true);
      await n.markCompleted('/x/b.mkv', tmdbPushPending: true);
      // b was un-marked again while its "watched" push was in flight.
      await n.markNotCompleted('/x/b.mkv');

      await n.settleTmdbPush({'/x/a.mkv': true, '/x/b.mkv': true});

      final rows = {
        for (final r in c.read(watchProgressProvider).values) r.filePath: r,
      };
      expect(rows['/x/a.mkv']!.tmdbPushPending, isFalse);
      expect(
        rows['/x/b.mkv']!.tmdbPushPending,
        isTrue,
        reason: 'its newer state still has to reach TMDB',
      );
    });

    test('a reconcile plan is applied in one write, or none', () async {
      final c = await containerWith([
        entry(path: '/x/a.mkv', isCompleted: true),
      ]);
      final n = notifierOf(c);
      arm(c);
      await n.applyWatchedSync(
        const WatchedReconcilePlan(upserts: {}, unwatch: {}),
      );
      expect(wroteSinceProbe(c), isFalse);

      await n.applyWatchedSync(
        const WatchedReconcilePlan(upserts: {}, unwatch: {'/x/a.mkv'}),
      );
      expect(c.read(watchProgressProvider).values.single.isCompleted, isFalse);
      expect(wroteSinceProbe(c), isTrue);
    });
  });

  group('migrateManualWatchedMarks', () {
    test('folds every legacy mark in with one write', () async {
      SharedPreferences.setMockInitialValues({
        'manual_watched_episodes': jsonEncode({
          'watched_episodes': {
            '95396': ['S01E01', 'S01E02'],
          },
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(c.dispose);

      final n = notifierOf(c);
      expect(await n.migrateManualWatchedMarks(), 2);
      expect(await n.migrateManualWatchedMarks(), 0, reason: 'once only');

      final index = c.read(watchedIndexProvider);
      expect(
        index.isEpisodeWatched(showId: 95396, season: 1, episode: 2),
        isTrue,
      );
      expect(prefs.getString('manual_watched_episodes'), isNull);
      expect(prefs.getString('manual_watched_episodes_archived_v1'), isNotNull);
    });
  });

  group('finishing a title, signed in', () {
    Future<(ProviderContainer, _Account)> signedIn({
      List<Movie> movies = const [],
      bool failWrites = false,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final account = _Account(failWrites: failWrites);
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          tmdbSessionProvider.overrideWith(_SignedIn.new),
          tmdbAccountServiceProvider.overrideWithValue(account),
          tmdbApiServiceProvider.overrideWithValue(_Catalogue(movies)),
        ],
      );
      addTearDown(c.dispose);
      return (c, account);
    }

    Future<void> finish(ProviderContainer c, String path) async {
      await notifierOf(c).updateProgress(
        entry(
          path: path,
          position: const Duration(minutes: 128),
          duration: const Duration(minutes: 130),
        ),
      );
      // The push is fire-and-forget; let it land.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    test('rates the film of that year, not the first "Dune"', () async {
      final (c, account) = await signedIn(
        movies: [
          Movie(id: 438631, title: 'Dune', releaseDate: '2021-09-15'),
          Movie(id: 841, title: 'Dune', releaseDate: '1984-12-14'),
        ],
      );
      await finish(c, '/x/Dune.1984.1080p.BluRay.mkv');

      expect(account.calls, ['rateMovie 841', 'watchlist 841']);
      expect(c.read(watchProgressProvider).values.single.movieId, 841);
    });

    test('rates nothing when the title is ambiguous', () async {
      final (c, account) = await signedIn(
        movies: [
          Movie(id: 438631, title: 'Dune', releaseDate: '2021-09-15'),
          Movie(id: 841, title: 'Dune', releaseDate: '1984-12-14'),
        ],
      );
      await finish(c, '/x/Dune.mkv');

      expect(account.calls, isEmpty);
    });

    test('a failed push is flagged for the next reconcile', () async {
      final (c, _) = await signedIn(
        movies: [Movie(id: 841, title: 'Dune', releaseDate: '1984-12-14')],
        failWrites: true,
      );
      await finish(c, '/x/Dune.1984.mkv');

      expect(
        c.read(watchProgressProvider).values.single.tmdbPushPending,
        isTrue,
      );
    });
  });

  group('getProgress', () {
    test('finds a row by path, not by hash', () async {
      final c = await containerWith([entry(path: '/x/a.mkv')]);

      expect(notifierOf(c).getProgress('/x/a.mkv'), isNotNull);
      expect(notifierOf(c).getProgress('/x/other.mkv'), isNull);
    });
  });

  group('round trip', () {
    test('a mutation survives a rebuild from prefs', () async {
      final c = await containerWith([]);
      await notifierOf(c).markCompleted('/x/a.mkv', showName: 'Lioness');

      final reloaded = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            c.read(sharedPreferencesProvider),
          ),
        ],
      );
      addTearDown(reloaded.dispose);

      final row = reloaded.read(watchProgressProvider).values.single;
      expect(row.showName, 'Lioness');
      expect(row.isCompleted, isTrue);
    });
  });
}

class _SignedIn extends TmdbSessionNotifier {
  @override
  TmdbSession? build() => TmdbSession(
    accessToken: 'user-token',
    accountId: 7,
    account: TmdbAccount(id: 7, username: 'tester'),
  );
}

class _Catalogue extends TmdbApiService {
  _Catalogue(this.movies) : super(accessToken: 'test');

  final List<Movie> movies;

  @override
  Future<List<Movie>> searchMovies(
    String query, {
    int page = 1,
    int? year,
  }) async => [
    for (final m in movies)
      if (year == null || m.year == '$year') m,
  ];
}

class _Account extends TmdbAccountService {
  _Account({this.failWrites = false}) : super(accessToken: 'test');

  final bool failWrites;
  final List<String> calls = [];

  @override
  Future<void> rateMovie({required int movieId, required double value}) async {
    if (failWrites) throw const SocketException('offline');
    calls.add('rateMovie $movieId');
  }

  @override
  Future<void> setWatchlist({
    required int accountId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool watchlist,
  }) async {
    if (failWrites) throw const SocketException('offline');
    calls.add('watchlist $mediaId');
  }
}
