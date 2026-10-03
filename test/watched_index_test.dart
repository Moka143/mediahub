import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/models/watched_index.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';

/// Build a progress entry with only the fields a given test cares about.
WatchProgress _entry({
  required String path,
  bool isCompleted = true,
  String? showName,
  int? showId,
  int? season,
  int? episode,
  String? episodeCode,
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
    episodeCode: episodeCode,
    movieId: movieId,
    position: position,
    duration: duration,
    lastWatched: DateTime(2026, 1, 1),
    isCompleted: isCompleted,
  );
}

void main() {
  group('WatchedIndex episodes', () {
    test('matches on the structured show id / season / episode key', () {
      final index = WatchedIndex.fromProgress([
        _entry(path: '/a.mkv', showId: 95396, season: 2, episode: 1),
      ]);

      expect(
        index.isEpisodeWatched(showId: 95396, season: 2, episode: 1),
        isTrue,
      );
      expect(
        index.isEpisodeWatched(showId: 95396, season: 2, episode: 2),
        isFalse,
      );
      expect(
        index.isEpisodeWatched(showId: 1399, season: 2, episode: 1),
        isFalse,
      );
    });

    test('ignores entries that are not completed', () {
      final index = WatchedIndex.fromProgress([
        _entry(
          path: '/a.mkv',
          isCompleted: false,
          showId: 95396,
          season: 2,
          episode: 1,
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 50),
        ),
      ]);

      expect(
        index.isEpisodeWatched(showId: 95396, season: 2, episode: 1),
        isFalse,
      );
      expect(index.isEmpty, isTrue);
    });

    test('90%+ without the completed flag still counts as watched', () {
      final index = WatchedIndex.fromProgress([
        _entry(
          path: '/a.mkv',
          isCompleted: false,
          showId: 95396,
          season: 2,
          episode: 1,
          showName: 'Severance',
          position: const Duration(minutes: 48),
          duration: const Duration(minutes: 50),
        ),
      ]);

      expect(
        index.isEpisodeWatched(showId: 95396, season: 2, episode: 1),
        isTrue,
      );
    });

    test('an entry with a show id is matched by that id only', () {
      // The name fallback used to run for keyed entries too, so every id
      // miss went looking for a name that merely contained the other: a
      // "Special Ops Lioness" row marked "Lioness" watched, and watching
      // "You" marked "Young Sheldon".
      final index = WatchedIndex.fromProgress([
        _entry(
          path: '/lioness.mkv',
          showId: 76479,
          season: 1,
          episode: 1,
          showName: 'Special Ops Lioness',
        ),
      ]);

      expect(
        index.isEpisodeWatched(
          showId: 113962,
          season: 1,
          episode: 1,
          showName: 'Special Ops Lioness',
        ),
        isFalse,
      );
    });

    test('falls back to name matching for entries with no show id', () {
      // Pre-showId entries: season/episode parsed from the filename but the
      // TMDB lookup never ran, so there is no id to key on.
      final index = WatchedIndex.fromProgress([
        _entry(
          path: '/Severance.S02E01.mkv',
          showName: 'Severance 2022',
          season: 2,
          episode: 1,
          episodeCode: 'S02E01',
        ),
      ]);

      expect(
        index.isEpisodeWatched(
          showId: 95396,
          season: 2,
          episode: 1,
          showName: 'Severance',
        ),
        isTrue,
        reason: 'a release year on one side only is still the same show',
      );
      expect(
        index.isEpisodeWatched(
          showId: 95396,
          season: 2,
          episode: 2,
          showName: 'Severance',
        ),
        isFalse,
      );
      expect(
        index.isEpisodeWatched(
          showId: 95396,
          season: 2,
          episode: 1,
          showName: 'Succession',
        ),
        isFalse,
        reason: 'a different show must not match on episode code alone',
      );
    });

    test('a name containing another is a different show', () {
      final index = WatchedIndex.fromProgress([
        _entry(path: '/a.mkv', showName: 'You', season: 1, episode: 1),
        _entry(path: '/b.mkv', showName: 'Dark Matter', season: 1, episode: 1),
        _entry(
          path: '/c.mkv',
          showName: 'The Office US',
          season: 2,
          episode: 3,
        ),
        _entry(path: '/d.mkv', showName: '進撃の巨人', season: 1, episode: 1),
      ]);

      bool watched(String name, int s, int e) => index.isEpisodeWatched(
        showId: 1,
        season: s,
        episode: e,
        showName: name,
      );

      expect(watched('Young Sheldon', 1, 1), isFalse);
      expect(watched('Dark', 1, 1), isFalse);
      expect(watched('The Office UK', 2, 3), isFalse);
      expect(watched('The Office', 2, 3), isTrue);
      expect(watched('進撃の巨人', 1, 1), isTrue);
      expect(watched('Attack on Titan', 1, 1), isFalse);
      expect(watched('', 1, 1), isFalse);
    });

    test('name fallback requires a show name — code alone is not enough', () {
      final index = WatchedIndex.fromProgress([
        _entry(
          path: '/mystery.mkv',
          showName: 'Severance',
          season: 1,
          episode: 3,
          episodeCode: 'S01E03',
        ),
      ]);

      expect(
        index.isEpisodeWatched(showId: 42, season: 1, episode: 3),
        isFalse,
        reason: 'without a show name, S01E03 would match every show',
      );
    });

    test('an entry with season+episode is never treated as a movie', () {
      final index = WatchedIndex.fromProgress([
        _entry(
          path: '/a.mkv',
          showId: 95396,
          season: 2,
          episode: 1,
          movieId: 550,
        ),
      ]);

      expect(index.isMovieWatched(550), isFalse);
      expect(
        index.isEpisodeWatched(showId: 95396, season: 2, episode: 1),
        isTrue,
      );
    });

    test('synthetic tmdb: and manual: paths are indexed like any other', () {
      // Reconcile writes these for episodes watched on another device and
      // never downloaded here; the migration writes manual: ones. Neither
      // has a real file, which must not matter.
      final index = WatchedIndex.fromProgress([
        _entry(
          path: 'tmdb:rated:1399/1/1',
          showId: 1399,
          season: 1,
          episode: 1,
        ),
        _entry(
          path: 'manual:watched:1399/1/2',
          showId: 1399,
          season: 1,
          episode: 2,
        ),
      ]);

      expect(
        index.isEpisodeWatched(showId: 1399, season: 1, episode: 1),
        isTrue,
      );
      expect(
        index.isEpisodeWatched(showId: 1399, season: 1, episode: 2),
        isTrue,
      );
      expect(index.episodeCount, 2);
    });
  });

  group('WatchedIndex movies', () {
    test('collects completed movie ids', () {
      final index = WatchedIndex.fromProgress([
        _entry(path: '/fight-club.mkv', movieId: 550),
        _entry(path: '/arrival.mkv', movieId: 329865),
        _entry(path: '/dune.mkv', isCompleted: false, movieId: 438631),
      ]);

      expect(index.isMovieWatched(550), isTrue);
      expect(index.isMovieWatched(329865), isTrue);
      expect(index.isMovieWatched(438631), isFalse);
      expect(index.watchedMovieIds, {550, 329865});
    });

    test('90%+ without the completed flag still counts as a watched movie', () {
      final index = WatchedIndex.fromProgress([
        _entry(
          path: '/dune.mkv',
          isCompleted: false,
          movieId: 438631,
          position: const Duration(minutes: 148),
          duration: const Duration(minutes: 155),
        ),
      ]);

      expect(index.isMovieWatched(438631), isTrue);
    });

    test('a completed movie with no resolved id is not indexed', () {
      final index = WatchedIndex.fromProgress([_entry(path: '/unknown.mkv')]);
      expect(index.watchedMovieIds, isEmpty);
      expect(index.isEmpty, isTrue);
    });

    test('watchedMovieIds is unmodifiable', () {
      final index = WatchedIndex.fromProgress([
        _entry(path: '/a.mkv', movieId: 550),
      ]);
      expect(() => index.watchedMovieIds.add(1), throwsUnsupportedError);
    });
  });

  group('empty index', () {
    test('answers false for everything', () {
      expect(
        WatchedIndex.empty.isEpisodeWatched(
          showId: 1,
          season: 1,
          episode: 1,
          showName: 'Anything',
        ),
        isFalse,
      );
      expect(WatchedIndex.empty.isMovieWatched(550), isFalse);
      expect(WatchedIndex.empty.isEmpty, isTrue);
    });
  });

  group('parseLegacyEpisodeMarks', () {
    test('recovers episode-level marks from the legacy blob', () {
      final raw = jsonEncode({
        'watched_episodes': {
          '95396': ['S01E01', 'S01E02'],
          '1399': ['S03E09'],
        },
        'watched_seasons': {
          '95396': [1],
        },
        'watched_shows': [1399],
      });

      final marks = parseLegacyEpisodeMarks(raw);

      expect(marks, hasLength(3));
      expect(marks, contains((showId: 95396, season: 1, episode: 1)));
      expect(marks, contains((showId: 95396, season: 1, episode: 2)));
      expect(marks, contains((showId: 1399, season: 3, episode: 9)));
    });

    test('season- and show-level marks are not expanded', () {
      // Expanding them needs the episode list per season, which is a TMDB
      // round-trip we can't make at startup. They stay in the archived blob.
      final raw = jsonEncode({
        'watched_episodes': <String, dynamic>{},
        'watched_seasons': {
          '95396': [1, 2],
        },
        'watched_shows': [1399],
      });

      expect(parseLegacyEpisodeMarks(raw), isEmpty);
    });

    test('skips malformed show ids and episode codes without throwing', () {
      final raw = jsonEncode({
        'watched_episodes': {
          'not-a-number': ['S01E01'],
          '95396': ['S01E01', 'garbage', '', 'S01', 42],
        },
      });

      final marks = parseLegacyEpisodeMarks(raw);

      expect(marks, [(showId: 95396, season: 1, episode: 1)]);
    });

    test('tolerates lowercase codes and multi-digit season/episode', () {
      final raw = jsonEncode({
        'watched_episodes': {
          '1399': ['s10e12', ' S02E03 '],
        },
      });

      final marks = parseLegacyEpisodeMarks(raw);

      expect(marks, contains((showId: 1399, season: 10, episode: 12)));
      expect(marks, contains((showId: 1399, season: 2, episode: 3)));
    });

    test('returns empty when the blob has no watched_episodes key', () {
      expect(parseLegacyEpisodeMarks(jsonEncode({'other': 1})), isEmpty);
    });
  });

  group('WatchProgress watched helpers', () {
    test('95% without the completed flag is effectively watched', () {
      final p = _entry(
        path: '/a.mkv',
        isCompleted: false,
        position: const Duration(minutes: 57),
        duration: const Duration(minutes: 60),
      );
      expect(p.shouldMarkCompleted, isTrue);
      expect(p.isEffectivelyWatched, isTrue);
      expect(p.followsRemoteUnwatch, isFalse);
    });

    test(
      'a finished episode with the file gone still does not follow TMDB unwatch',
      () {
        final p = _entry(
          path: '/gone.mkv',
          isCompleted: true,
          position: Duration.zero,
          duration: const Duration(minutes: 43),
        );
        expect(p.shouldMarkCompleted, isFalse);
        expect(p.isEffectivelyWatched, isTrue);
        expect(p.followsRemoteUnwatch, isFalse);
      },
    );

    test(
      'an explicit mark with no playback still follows a remote unwatch',
      () {
        final p = _entry(path: '/a.mkv', isCompleted: true);
        expect(p.shouldMarkCompleted, isFalse);
        expect(p.isEffectivelyWatched, isTrue);
        expect(p.followsRemoteUnwatch, isTrue);
      },
    );
  });
}
