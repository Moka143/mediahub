import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/watch_progress.dart';
import '../models/watched_index.dart';
import '../services/app_logger.dart';
import '../services/json_prefs_store.dart';
import '../services/tmdb_watched_sync.dart';
import '../utils/formatters.dart';
import '../utils/media_names.dart';
import 'local_media_provider.dart';
import 'settings_provider.dart';
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
/// watched-check through this index (or [isMovieWatchedProvider]) — the
/// hand-rolled `.values.any(...)` scans that used to live in the episodes
/// drawer and the movie screens had each drifted to different matching
/// rules.
final watchedIndexProvider = Provider<WatchedIndex>((ref) {
  final progress = ref.watch(watchProgressProvider);
  return WatchedIndex.fromProgress(progress.values);
});

/// Whether a specific movie is watched.
final isMovieWatchedProvider = Provider.family<bool, int>((ref, movieId) {
  return ref.watch(watchedIndexProvider).isMovieWatched(movieId);
});

/// One-time recovery of watched marks stranded in the legacy
/// `manual_watched_episodes` store. See
/// [WatchProgressNotifier.migrateManualWatchedMarks].
Future<int> migrateManualWatchedMarks(WidgetRef ref) =>
    ref.read(watchProgressProvider.notifier).migrateManualWatchedMarks();

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

  for (final entry in episodes.entries) {
    final showId = int.tryParse(entry.key);
    if (showId == null) continue;
    final codes = entry.value;
    if (codes is! List) continue;
    for (final code in codes) {
      if (code is! String) continue;
      // The shared parser — the app wrote these as plain `S01E05` codes.
      final parsed = parseEpisodeCode(code.trim());
      if (parsed == null) continue;
      out.add((showId: showId, season: parsed.season, episode: parsed.episode));
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

/// Below this, a row is a peek rather than something to continue.
const double _continueWatchingFloor = 0.05;

/// Provider for "Continue Watching" items (in progress, not completed).
/// Filters out items whose file is no longer in the library.
final continueWatchingProvider = Provider<List<WatchProgress>>((ref) {
  final progress = ref.watch(watchProgressProvider);
  final libraryPaths = ref.watch(libraryPathsProvider);

  final validProgress = progress.values.where((p) {
    // 90%+ is credits — same bar as `shouldMarkCompleted`. Don't keep
    // a row around just because the completed flag never got persisted.
    if (p.isEffectivelyWatched || p.progress <= _continueWatchingFloor) {
      return false;
    }
    return isProgressPlayable(p.filePath, libraryPaths);
  }).toList();

  // Sort by last watched (most recent first)
  validProgress.sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
  return validProgress;
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
  late JsonPrefsStore _store;

  @override
  Map<String, WatchProgress> build() {
    _store = JsonPrefsStore(
      ref.watch(sharedPreferencesProvider),
      _watchProgressKey,
    );
    var promoted = false;
    // Entry by entry: one unreadable row used to make the whole history
    // load as empty — and the next playback tick (≤10 s) saved that over the
    // only copy. Now the bad row is skipped and the raw value quarantined.
    final rows = _store.readList((json) {
      var progress = WatchProgress.fromJson(json! as Map<String, dynamic>);
      if (!progress.isCompleted && progress.shouldMarkCompleted) {
        progress = progress.copyWith(isCompleted: true);
        promoted = true;
      }
      return progress;
    });
    if (promoted) unawaited(Future.microtask(_saveProgress));
    return {for (final p in rows) p.fileHash: p};
  }

  /// Save progress to SharedPreferences
  Future<void> _saveProgress() async {
    try {
      await _store.write(state.values.map((p) => p.toJson()).toList());
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
      // Fire-and-forget — local state is already saved; a push that fails
      // is flagged pending and retried by the next reconcile.
      unawaited(_pushWatchedToTmdb(updatedProgress));
    }
  }

  /// Tell TMDB that [p] was watched — by rating it, the app's "watched"
  /// proxy — when it can be identified unambiguously.
  ///
  /// This used to search TMDB for the title with its year stripped and
  /// rate the **first hit**: finishing `Dune.1984…` rated the 2021 film, and
  /// any home video without an episode marker rated some random movie. The
  /// shared resolver answers only when exactly one result is the same title
  /// from the same year, and nothing is written otherwise.
  Future<void> _pushWatchedToTmdb(WatchProgress p) async {
    final sync = ref.read(tmdbWatchedSyncProvider);
    if (sync == null) return;

    final WatchedTarget? target;
    try {
      target = await sync.targetFor(
        path: p.filePath,
        showName: p.showName,
        season: p.seasonNumber,
        episode: p.episodeNumber,
        showId: p.showId,
        movieId: p.movieId,
      );
    } catch (e) {
      AppLog.w('[WatchProgress] could not identify ${p.filePath}: $e');
      if (ref.mounted) {
        await settleTmdbPush(const {}, markPending: {p.filePath});
      }
      return;
    }
    if (target == null) return; // Not on TMDB, or not unambiguously.

    if (!ref.mounted) return;
    // Persist the id it resolved, so the reconcile and the UI matchers use it
    // directly next time instead of searching again.
    await _attachIds(p.filePath, target);

    try {
      await sync.push(target, watched: true);
    } catch (e) {
      AppLog.e('[WatchProgress] auto-push to TMDB failed: $e');
      if (ref.mounted) {
        await settleTmdbPush(const {}, markPending: {p.filePath});
      }
    }
  }

  Future<void> _attachIds(String filePath, WatchedTarget target) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];
    if (existing == null) return;
    final updated = switch (target) {
      EpisodeTarget(:final showId) || ShowTarget(:final showId) =>
        existing.showId == null ? existing.copyWith(showId: showId) : null,
      MovieTarget(:final movieId) =>
        existing.movieId == null ? existing.copyWith(movieId: movieId) : null,
    };
    if (updated == null) return;
    state = {...state, hash: updated};
    await _saveProgress();
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
  /// `continueWatchingProvider` filters that out, so a "mark as watched" on
  /// an unopened file correctly does NOT add it to Continue Watching.
  ///
  /// [tmdbPushPending] records whether TMDB still has to hear about it; null
  /// leaves an existing row's flag as it is.
  Future<void> markCompleted(
    String filePath, {
    String? showName,
    int? showId,
    int? seasonNumber,
    int? episodeNumber,
    int? movieId,
    String? posterPath,
    bool? tmdbPushPending,
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
        tmdbPushPending: tmdbPushPending,
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
        tmdbPushPending: tmdbPushPending ?? false,
      );
      state = {...state, hash: synthetic};
    }
    await _saveProgress();
  }

  /// Mark a file as not completed (unwatched). [tmdbPushPending] as in
  /// [markCompleted].
  Future<void> markNotCompleted(
    String filePath, {
    bool? tmdbPushPending,
  }) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];

    if (existing != null) {
      final updated = existing.copyWith(
        isCompleted: false,
        position: Duration.zero,
        lastWatched: DateTime.now(),
        tmdbPushPending: tmdbPushPending,
      );
      state = {...state, hash: updated};
      await _saveProgress();
    }
  }

  /// Record the outcome of TMDB pushes in one write.
  ///
  /// [settled] maps a path to the watched state TMDB now has for it; its
  /// pending flag is cleared — but only if the row still *is* in that state.
  /// A row changed again while the push was in flight keeps its flag, so
  /// its newer state is pushed next time rather than overwritten by
  /// TMDB's older one. Rows in [markPending] get the flag.
  Future<void> settleTmdbPush(
    Map<String, bool> settled, {
    Set<String> markPending = const {},
  }) async {
    final next = Map<String, WatchProgress>.of(state);
    var changed = false;
    settled.forEach((path, watched) {
      final hash = WatchProgress.generateHash(path);
      final row = next[hash];
      if (row == null || !row.tmdbPushPending) return;
      if (row.isEffectivelyWatched != watched) return;
      next[hash] = row.copyWith(tmdbPushPending: false);
      changed = true;
    });
    for (final path in markPending) {
      final hash = WatchProgress.generateHash(path);
      final row = next[hash];
      if (row == null || row.tmdbPushPending) continue;
      next[hash] = row.copyWith(tmdbPushPending: true);
      changed = true;
    }
    if (!changed) return;
    state = next;
    await _saveProgress();
  }

  /// Apply what a TMDB reconcile decided ([planWatchedReconcile]) in one
  /// write — or none, when it decided nothing. Every launch used to rewrite
  /// the whole history once per rated movie, whether or not anything had
  /// changed.
  Future<void> applyWatchedSync(WatchedReconcilePlan plan) async {
    if (plan.isEmpty) return;
    final next = {...state, ...plan.upserts};
    final now = DateTime.now();
    for (final path in plan.unwatch) {
      final hash = WatchProgress.generateHash(path);
      final row = next[hash];
      if (row == null) continue;
      next[hash] = row.copyWith(
        isCompleted: false,
        position: Duration.zero,
        lastWatched: now,
      );
    }
    state = next;
    await _saveProgress();
  }

  /// Fold the legacy `manual_watched_episodes` marks into this store, once.
  ///
  /// Episode-level marks convert exactly and become synthetic completed
  /// entries under a `manual:watched:<showId>/<season>/<episode>` path — the
  /// same mechanism the TMDB reconcile uses for episodes rated on another
  /// device but never downloaded here. Written in one save, not one per mark.
  ///
  /// Season-level and show-level marks are *not* expanded: doing so needs the
  /// episode list for each season, which means a TMDB round-trip we can't make
  /// synchronously at startup. Rather than drop them, the whole legacy blob is
  /// archived under [_manualWatchedArchiveKey] so a later pass can expand them.
  ///
  /// Idempotent: the presence of the legacy key is itself the guard, so once
  /// the key has been renamed this is a no-op.
  Future<int> migrateManualWatchedMarks() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_manualWatchedKey);
    if (raw == null) return 0;

    var recovered = 0;
    try {
      final now = DateTime.now();
      final next = Map<String, WatchProgress>.of(state);
      for (final m in parseLegacyEpisodeMarks(raw)) {
        final path = 'manual:watched:${m.showId}/${m.season}/${m.episode}';
        final hash = WatchProgress.generateHash(path);
        final existing = next[hash];
        next[hash] =
            existing?.copyWith(isCompleted: true) ??
            WatchProgress(
              fileHash: hash,
              filePath: path,
              showId: m.showId,
              seasonNumber: m.season,
              episodeNumber: m.episode,
              episodeCode: Formatters.episodeCode(m.season, m.episode),
              position: Duration.zero,
              duration: Duration.zero,
              lastWatched: now,
              isCompleted: true,
            );
        recovered++;
      }
      if (recovered > 0) {
        state = next;
        await _saveProgress();
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
  ///
  /// The existence checks run asynchronously and together; one blocking
  /// stat per row on the UI isolate was a visible hitch on a long history.
  Future<void> cleanupStaleEntries() async {
    final snapshot = state;
    final real = [
      for (final p in snapshot.values)
        if (!WatchProgress.isSyntheticPath(p.filePath)) p.filePath,
    ];
    final present = await Future.wait(real.map((path) => File(path).exists()));
    final gone = {
      for (var i = 0; i < real.length; i++)
        if (!present[i]) real[i],
    };
    if (gone.isEmpty || !ref.mounted) return;

    // Applied to the current state, not the snapshot: playback may have
    // written while the stats ran.
    final newState = <String, WatchProgress>{};
    var changed = false;
    for (final entry in state.entries) {
      final p = entry.value;
      if (!gone.contains(p.filePath)) {
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

  /// Get progress by file path
  WatchProgress? getProgress(String filePath) {
    final hash = WatchProgress.generateHash(filePath);
    return state[hash];
  }
}
