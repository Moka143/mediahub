import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/watch_progress.dart';
import '../models/watched_index.dart';
import '../services/app_logger.dart';
import '../services/tmdb_account_service.dart';
import '../utils/formatters.dart';
import '../utils/media_names.dart';
import '../utils/platform_utils.dart';
import 'local_media_provider.dart';
import 'settings_provider.dart';
import 'shows_provider.dart';
import 'tmdb_account_provider.dart';

/// Key for storing watch progress in SharedPreferences
const _watchProgressKey = 'watch_progress';

/// Legacy key for the old standalone "manual watched" store. Nothing has
/// read it since the dead-code purge in 80ec980, which removed its last UI
/// reader but left the store — and any marks users had already saved into
/// it — stranded. [migrateManualWatchedMarks] folds those marks into
/// [watchProgressProvider] and renames the key to [_manualWatchedArchiveKey]
/// so the raw data is preserved rather than destroyed.
const _manualWatchedKey = 'manual_watched_episodes';
const _manualWatchedArchiveKey = 'manual_watched_episodes_archived_v1';

/// Provider for all watch progress entries
final watchProgressProvider =
    NotifierProvider<WatchProgressNotifier, Map<String, WatchProgress>>(
      WatchProgressNotifier.new,
    );

/// The single source of truth for "has this been watched?".
///
/// Derived from [watchProgressProvider], so it rebuilds once per change to
/// the progress map rather than being re-scanned per query. Route every UI
/// watched-check through [isEpisodeWatchedProvider] /
/// [isMovieWatchedProvider] / this index — the hand-rolled `.values.any(...)`
/// scans that used to live in the episodes drawer and the movie screens had
/// each drifted to different matching rules.
final watchedIndexProvider = Provider<WatchedIndex>((ref) {
  final progress = ref.watch(watchProgressProvider);
  return WatchedIndex.fromProgress(progress.values);
});

/// Whether a specific episode is watched. Pass [showName] so entries that
/// predate persisted show ids can still be matched by name.
final isEpisodeWatchedProvider =
    Provider.family<
      bool,
      ({int showId, int season, int episode, String? showName})
    >((ref, params) {
      return ref
          .watch(watchedIndexProvider)
          .isEpisodeWatched(
            showId: params.showId,
            season: params.season,
            episode: params.episode,
            showName: params.showName,
          );
    });

/// Whether a specific movie is watched.
final isMovieWatchedProvider = Provider.family<bool, int>((ref, movieId) {
  return ref.watch(watchedIndexProvider).isMovieWatched(movieId);
});

/// One-time recovery of watched marks stranded in the legacy
/// `manual_watched_episodes` store.
///
/// Episode-level marks convert exactly and become synthetic completed
/// entries under a `manual:watched:<showId>/<season>/<episode>` path — the
/// same mechanism `reconcileWatchedWithTmdb` already uses for episodes
/// rated on another device but never downloaded here.
///
/// Season-level and show-level marks are *not* expanded: doing so needs the
/// episode list for each season, which means a TMDB round-trip we can't make
/// synchronously at startup. Rather than drop them, the whole legacy blob is
/// archived under [_manualWatchedArchiveKey] so a later pass can expand them.
///
/// Idempotent: the presence of the legacy key is itself the guard, so once
/// the key has been renamed this is a no-op.
Future<int> migrateManualWatchedMarks(WidgetRef ref) async {
  final prefs = ref.read(sharedPreferencesProvider);
  final raw = prefs.getString(_manualWatchedKey);
  if (raw == null) return 0;

  var recovered = 0;
  try {
    final marks = parseLegacyEpisodeMarks(raw);
    final notifier = ref.read(watchProgressProvider.notifier);
    for (final m in marks) {
      await notifier.markCompleted(
        'manual:watched:${m.showId}/${m.season}/${m.episode}',
        showId: m.showId,
        seasonNumber: m.season,
        episodeNumber: m.episode,
      );
      recovered++;
    }
    AppLog.i(
      '[WatchProgress] recovered $recovered stranded watched mark(s) from '
      'the legacy manual-watched store',
    );
  } catch (e) {
    AppLog.e('[WatchProgress] manual-watched migration failed: $e');
    // Fall through and archive anyway — leaving the key in place would
    // retry a blob we already know we can't parse on every launch.
  }

  await prefs.setString(_manualWatchedArchiveKey, raw);
  await prefs.remove(_manualWatchedKey);
  return recovered;
}

/// Parse episode-level marks out of the legacy manual-watched JSON blob.
///
/// Shape: `{"watched_episodes": {"<showId>": ["S01E05", ...]}, ...}`.
/// Malformed show ids and episode codes are skipped rather than throwing —
/// this runs at startup on user data of unknown vintage, and recovering
/// nine of ten marks beats recovering none.
@visibleForTesting
List<({int showId, int season, int episode})> parseLegacyEpisodeMarks(
  String rawJson,
) {
  final out = <({int showId, int season, int episode})>[];
  final json = jsonDecode(rawJson) as Map<String, dynamic>;
  final episodes = json['watched_episodes'] as Map<String, dynamic>?;
  if (episodes == null) return out;

  final codePattern = RegExp(r'^s(\d{1,3})e(\d{1,3})$', caseSensitive: false);
  for (final entry in episodes.entries) {
    final showId = int.tryParse(entry.key);
    if (showId == null) continue;
    final codes = entry.value;
    if (codes is! List) continue;
    for (final code in codes) {
      if (code is! String) continue;
      final m = codePattern.firstMatch(code.trim());
      if (m == null) continue;
      final season = int.tryParse(m.group(1)!);
      final episode = int.tryParse(m.group(2)!);
      if (season == null || episode == null) continue;
      out.add((showId: showId, season: season, episode: episode));
    }
  }
  return out;
}

/// Paths currently present in the scanned library, for O(1) "is this still
/// on disk?" checks.
///
/// Null while the first scan is in flight — callers treat that as "don't
/// know yet" and stay optimistic rather than filtering everything out,
/// which would flash an empty Continue Watching row on cold start.
///
/// This replaces a per-entry `File(...).existsSync()` in the providers
/// below. Those rebuild on *every* watch-progress write — which happens on
/// every position update during playback — so the old form stat'd the whole
/// progress map several times a second while a video was playing.
final libraryPathsProvider = Provider<Set<String>?>((ref) {
  final files = ref.watch(localMediaFilesProvider).value;
  if (files == null) return null;
  return {for (final f in files) f.path};
});

/// Whether a watch-progress entry still points at something playable.
///
/// Membership in the scanned library, not a raw stat: an entry outside the
/// configured library folder is not something the app can offer to play, and
/// synthetic watched-only entries never are.
@visibleForTesting
bool isProgressPlayable(String filePath, Set<String>? libraryPaths) {
  if (WatchProgress.isSyntheticPath(filePath)) return false;
  // First scan hasn't landed — assume present rather than hiding real rows.
  if (libraryPaths == null) return true;
  return libraryPaths.contains(filePath);
}

/// Provider for "Continue Watching" items (in progress, not completed).
/// Filters out items whose file is no longer in the library.
final continueWatchingProvider = Provider<List<WatchProgress>>((ref) {
  final progress = ref.watch(watchProgressProvider);
  final libraryPaths = ref.watch(libraryPathsProvider);

  final validProgress = progress.values.where((p) {
    // 90%+ is credits — same bar as `shouldMarkCompleted`. Don't keep
    // a row around just because the completed flag never got persisted.
    if (p.isEffectivelyWatched || p.progress <= 0.05) {
      return false;
    }
    return isProgressPlayable(p.filePath, libraryPaths);
  }).toList();

  // Sort by last watched (most recent first)
  validProgress.sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
  return validProgress;
});

/// Provider for completed (watched) items that are still in the library.
///
/// Note this is deliberately NOT the source of truth for "is this watched?" —
/// see [watchedIndexProvider], which keeps the mark even after the file is
/// deleted. This provider is for surfaces that need something playable.
final watchedItemsProvider = Provider<List<WatchProgress>>((ref) {
  final progress = ref.watch(watchProgressProvider);
  final libraryPaths = ref.watch(libraryPathsProvider);
  return progress.values
      .where(
        (p) =>
            p.isEffectivelyWatched &&
            isProgressPlayable(p.filePath, libraryPaths),
      )
      .toList()
    ..sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
});

/// Provider for watch progress of specific file
final fileWatchProgressProvider = Provider.family<WatchProgress?, String>((
  ref,
  filePath,
) {
  final progress = ref.watch(watchProgressProvider);
  final hash = WatchProgress.generateHash(filePath);
  return progress[hash];
});

/// Notifier for managing watch progress
class WatchProgressNotifier extends Notifier<Map<String, WatchProgress>> {
  @override
  Map<String, WatchProgress> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    var promoted = false;
    final map = _loadProgress(prefs, promoted: (v) => promoted = v);
    if (promoted) {
      Future.microtask(() {
        _saveProgress();
      });
    }
    return map;
  }

  /// Load progress from SharedPreferences
  Map<String, WatchProgress> _loadProgress(
    SharedPreferences prefs, {
    void Function(bool promoted)? promoted,
  }) {
    try {
      final jsonString = prefs.getString(_watchProgressKey);
      if (jsonString == null) return {};

      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      final map = <String, WatchProgress>{};
      var didPromote = false;

      for (final item in jsonList) {
        var progress = WatchProgress.fromJson(item as Map<String, dynamic>);
        if (!progress.isCompleted && progress.shouldMarkCompleted) {
          progress = progress.copyWith(isCompleted: true);
          didPromote = true;
        }
        map[progress.fileHash] = progress;
      }

      promoted?.call(didPromote);
      return map;
    } catch (e) {
      AppLog.e('[WatchProgress] Error loading watch progress: $e');
      return {};
    }
  }

  /// Save progress to SharedPreferences
  Future<void> _saveProgress() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final jsonList = state.values.map((p) => p.toJson()).toList();
      await prefs.setString(_watchProgressKey, jsonEncode(jsonList));
    } catch (e) {
      AppLog.e('[WatchProgress] Error saving watch progress: $e');
    }
  }

  /// Update or create progress for a file.
  ///
  /// When the entry crosses the 90% threshold for the first time we flip
  /// `isCompleted = true` AND fire a best-effort TMDB rating POST so the
  /// "watched" mark propagates across devices. Without this, finishing
  /// an episode only updates local state — only the manual
  /// "Mark as watched" menu used to hit TMDB.
  Future<void> updateProgress(WatchProgress progress) async {
    final justCompleted = progress.shouldMarkCompleted && !progress.isCompleted;
    final updatedProgress = justCompleted
        ? progress.copyWith(isCompleted: true)
        : progress;

    state = {...state, updatedProgress.fileHash: updatedProgress};
    await _saveProgress();

    if (justCompleted) {
      // Fire-and-forget — local state is already saved, network errors
      // are reconciled on the next `reconcileWatchedWithTmdb` pass.
      unawaited(_pushWatchedToTmdb(updatedProgress));
    }
  }

  Future<void> _pushWatchedToTmdb(WatchProgress p) async {
    if (!ref.read(isTmdbSignedInProvider)) return;
    final acct = ref.read(tmdbAccountServiceProvider);
    try {
      var showId = p.showId;
      var movieId = p.movieId;
      final season = p.seasonNumber;
      final episode = p.episodeNumber;
      final isEpisode = season != null && episode != null;

      if (showId == null &&
          isEpisode &&
          p.showName != null &&
          p.showName!.isNotEmpty) {
        final shows = await ref
            .read(tmdbApiServiceProvider)
            .searchShows(p.showName!);
        if (shows.isNotEmpty) showId = shows.first.id;
      }

      // Movies got no equivalent, so finishing one never reached TMDB:
      // `movieId` is only ever set by "Mark as watched", which resolves it
      // by name. Playback had no way to. Resolve it the same way the episode
      // branch above resolves a show id.
      if (movieId == null &&
          !isEpisode &&
          !WatchProgress.isSyntheticPath(p.filePath)) {
        final name = p.showName?.isNotEmpty == true
            ? p.showName!
            : cleanMediaTitle(basenameOf(p.filePath));
        if (name.isNotEmpty) {
          final movies = await ref
              .read(tmdbApiServiceProvider)
              .searchMovies(name);
          if (movies.isNotEmpty) movieId = movies.first.id;
        }
      }

      if (showId != null && season != null && episode != null) {
        await acct.rateEpisode(
          seriesId: showId,
          seasonNumber: season,
          episodeNumber: episode,
          value: TmdbAccountService.watchedRatingValue,
        );
        if (p.showId == null) {
          final hash = p.fileHash;
          final existing = state[hash];
          if (existing != null) {
            state = {...state, hash: existing.copyWith(showId: showId)};
            await _saveProgress();
          }
        }
      } else if (movieId != null) {
        await acct.rateMovie(
          movieId: movieId,
          value: TmdbAccountService.watchedRatingValue,
        );
        if (p.movieId == null) {
          // Persist it so the next pass — and the TMDB reconcile — skip the
          // search, the same way the episode branch persists the show id.
          final existing = state[p.fileHash];
          if (existing != null) {
            state = {...state, p.fileHash: existing.copyWith(movieId: movieId)};
            await _saveProgress();
          }
        }
      }
    } catch (e) {
      AppLog.e('[WatchProgress] auto-push to TMDB failed: $e');
    }
  }

  /// Persist a TMDB show id onto an existing progress row once playback
  /// resolves it. Also retries the watched rating POST if this title is
  /// already finished — Lioness rows were saved with `showId: null`, so
  /// the original auto-push was a no-op.
  Future<void> attachShowId(String filePath, int showId) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];
    if (existing == null || existing.showId == showId) return;
    final updated = existing.copyWith(showId: showId);
    state = {...state, hash: updated};
    await _saveProgress();
    if (updated.isEffectivelyWatched) {
      // Fire-and-forget, as above.
      unawaited(_pushWatchedToTmdb(updated));
    }
  }

  /// Update position only (for frequent updates during playback)
  Future<void> updatePosition(
    String filePath, {
    required Duration position,
    required Duration duration,
  }) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];

    if (existing != null) {
      final updated = existing.copyWith(
        position: position,
        duration: duration,
        lastWatched: DateTime.now(),
      );
      await updateProgress(updated);
    }
  }

  /// Create new progress entry for a file
  Future<void> createProgress({
    required String filePath,
    String? showName,
    int? showId,
    int? seasonNumber,
    int? episodeNumber,
    String? episodeTitle,
    String? posterPath,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
  }) async {
    final hash = WatchProgress.generateHash(filePath);

    final progress = WatchProgress(
      fileHash: hash,
      filePath: filePath,
      showName: showName,
      showId: showId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeCode: Formatters.episodeCodeOrNull(seasonNumber, episodeNumber),
      episodeTitle: episodeTitle,
      posterPath: posterPath,
      position: position,
      duration: duration,
      lastWatched: DateTime.now(),
    );

    await updateProgress(progress);
  }

  /// Mark a file as completed (watched).
  ///
  /// Upserts — if no `WatchProgress` entry exists for this file yet (the
  /// common case for freshly-downloaded items the user has never opened),
  /// synthesises a minimal one so the "watched" state is recorded and the
  /// UI's checkmark/filter picks it up immediately. Caller passes file
  /// metadata for the new entry; all fields are optional and the entry
  /// degrades gracefully without them.
  ///
  /// A synthetic entry has `position=0, duration=0`, so `progress == 0.0`.
  /// `continueWatchingProvider` filters that out (it requires `progress >
  /// 0.05`), so a "mark as watched" on an unopened file correctly does
  /// NOT add it to Continue Watching.
  Future<void> markCompleted(
    String filePath, {
    String? showName,
    int? showId,
    int? seasonNumber,
    int? episodeNumber,
    int? movieId,
    String? posterPath,
  }) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];

    if (existing != null) {
      // Upsert: if the caller supplied a movieId / showId we didn't have
      // before, persist it so the reconcile + UI matchers can use the
      // structured key on future passes.
      final updated = existing.copyWith(
        isCompleted: true,
        lastWatched: DateTime.now(),
        movieId: movieId ?? existing.movieId,
        showId: showId ?? existing.showId,
      );
      state = {...state, hash: updated};
    } else {
      final synthetic = WatchProgress(
        fileHash: hash,
        filePath: filePath,
        showName: showName,
        showId: showId,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        episodeCode: Formatters.episodeCodeOrNull(seasonNumber, episodeNumber),
        movieId: movieId,
        posterPath: posterPath,
        position: Duration.zero,
        duration: Duration.zero,
        lastWatched: DateTime.now(),
        isCompleted: true,
      );
      state = {...state, hash: synthetic};
    }
    await _saveProgress();
  }

  /// Mark a file as not completed (unwatched)
  Future<void> markNotCompleted(String filePath) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];

    if (existing != null) {
      final updated = existing.copyWith(
        isCompleted: false,
        position: Duration.zero,
        lastWatched: DateTime.now(),
      );
      state = {...state, hash: updated};
      await _saveProgress();
    }
  }

  /// Clear progress for a specific file
  Future<void> clearProgress(String filePath) async {
    final hash = WatchProgress.generateHash(filePath);
    final newState = Map<String, WatchProgress>.from(state);
    newState.remove(hash);
    state = newState;
    await _saveProgress();
  }

  /// Remove watch progress entries whose files no longer exist on disk.
  ///
  /// Finished watches survive so the tag outlives delete / re-download.
  /// Position is left alone — zeroing it made a 90%+ episode look like
  /// an unplayed explicit mark, and the next TMDB pull wiped the tag.
  Future<void> cleanupStaleEntries() async {
    final newState = <String, WatchProgress>{};
    var changed = false;

    for (final entry in state.entries) {
      final p = entry.value;
      final keepFile =
          WatchProgress.isSyntheticPath(p.filePath) ||
          File(p.filePath).existsSync();
      if (keepFile) {
        newState[entry.key] = p;
        continue;
      }
      if (!p.isEffectivelyWatched) {
        changed = true;
        continue;
      }
      if (!p.isCompleted) {
        newState[entry.key] = p.copyWith(isCompleted: true);
        changed = true;
      } else {
        newState[entry.key] = p;
      }
    }

    if (!changed) return;
    state = newState;
    await _saveProgress();
  }

  /// Clear all progress
  Future<void> clearAll() async {
    state = {};
    await _saveProgress();
  }

  /// Get progress by file path
  WatchProgress? getProgress(String filePath) {
    final hash = WatchProgress.generateHash(filePath);
    return state[hash];
  }
}
