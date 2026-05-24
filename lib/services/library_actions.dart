import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../models/watch_progress.dart';
import '../providers/local_media_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import 'tmdb_account_service.dart';

/// Cache of show-name → TMDB show id so the watched-sync doesn't hit
/// `/search/tv` on every Mark watched / Mark not watched click. A null
/// entry is also cached so we don't retry a confirmed miss either.
final Map<String, int?> _showIdCache = {};

/// Look up a TMDB show id by name. Returns null on miss / network failure
/// (the local mark already succeeded, so a missing id just means we skip
/// the TMDB push for this item).
Future<int?> _resolveShowId(WidgetRef ref, String? showName) async {
  if (showName == null || showName.isEmpty) return null;
  if (_showIdCache.containsKey(showName)) return _showIdCache[showName];
  try {
    final shows = await ref.read(tmdbServiceProvider).searchShows(showName);
    final id = shows.isNotEmpty ? shows.first.id : null;
    _showIdCache[showName] = id;
    return id;
  } catch (_) {
    _showIdCache[showName] = null;
    return null;
  }
}

/// Outcome of a delete action — lets the UI surface a useful toast.
class LibraryDeleteResult {
  final bool fileRemoved;
  final bool torrentRemoved;
  final String? error;

  const LibraryDeleteResult({
    required this.fileRemoved,
    required this.torrentRemoved,
    this.error,
  });

  bool get success => fileRemoved || torrentRemoved;
}

/// Try to find the qBittorrent torrent whose content path contains this file.
/// Returns the hash, or null if none matches.
String? _findTorrentHashForFile(WidgetRef ref, LocalMediaFile file) {
  if (file.torrentHash != null && file.torrentHash!.isNotEmpty) {
    return file.torrentHash;
  }
  final torrents = ref.read(torrentListProvider).torrents;
  for (final t in torrents) {
    final cp = t.contentPath;
    if (cp.isEmpty) continue;
    // qBit returns either the file path (single-file torrent) or the
    // containing folder (multi-file). Prefix match handles both.
    if (file.path.startsWith(cp) || cp == file.path) {
      return t.hash;
    }
  }
  return null;
}

/// Delete a library item end-to-end.
///
/// - If a matching qBittorrent torrent is found, asks qBit to delete the
///   torrent *and* its files. qBit handles file removal more reliably than
///   us racing it (especially when files are still open by the seeding
///   process).
/// - Otherwise, falls back to a direct filesystem delete.
/// - Always invalidates the local-media providers and cleans stale watch
///   progress entries.
Future<LibraryDeleteResult> deleteLibraryItem(
  WidgetRef ref,
  LocalMediaFile file,
) async {
  final hash = _findTorrentHashForFile(ref, file);
  if (hash != null) {
    try {
      final ok = await ref.read(torrentListProvider.notifier).deleteTorrents([
        hash,
      ], deleteFiles: true);
      if (ok) {
        // Torrent delete already invalidates media providers + cleans stale
        // watch progress entries (see TorrentListNotifier.deleteTorrents).
        return const LibraryDeleteResult(
          fileRemoved: true,
          torrentRemoved: true,
        );
      }
    } catch (e) {
      debugPrint('[LibraryActions] qBit delete failed for $hash: $e');
    }
    // qBit refused — fall through to direct file delete.
  }

  // Direct filesystem delete fallback.
  try {
    final f = File(file.path);
    if (await f.exists()) {
      await f.delete();
    }
    ref.invalidate(localMediaStreamProvider);
    ref.invalidate(localMediaFilesProvider);
    await ref.read(watchProgressProvider.notifier).cleanupStaleEntries();
    return LibraryDeleteResult(fileRemoved: true, torrentRemoved: hash != null);
  } catch (e) {
    debugPrint('[LibraryActions] File delete failed for ${file.path}: $e');
    return LibraryDeleteResult(
      fileRemoved: false,
      torrentRemoved: false,
      error: e.toString(),
    );
  }
}

/// Mark a library item as watched.
///
/// Bidirectional with TMDB:
/// - Local: sets `WatchProgress.isCompleted = true` for this file path
///   (drives the checkmark badge).
/// - TMDB rating: rates the item 10/10 as a "watched" proxy. TMDB has no
///   native "mark watched" endpoint, but ratings ARE per-episode, so a
///   rating is the only thing that round-trips per-episode state.
/// - TMDB watchlist: for movies and whole-show entries, also removes from
///   the user's watchlist (the "done" proxy — irrelevant for episodes
///   since the watchlist is show-level).
///
/// Sync failures are non-fatal — local state is the source of truth, and
/// the next call to [syncWatchedFromTmdb] will re-reconcile.
Future<void> markAsWatched(
  WidgetRef ref,
  LocalMediaFile file, {
  int? tmdbMovieId,
  int? tmdbShowId,
}) async {
  // Forward enough metadata that the notifier can synthesise a fresh
  // `WatchProgress` entry if none exists yet (the common case for items
  // the user has downloaded but never opened). Without this, "Mark as
  // watched" silently no-ops on those — the bug behind the user's
  // "menu actions don't work" report.
  await ref
      .read(watchProgressProvider.notifier)
      .markCompleted(
        file.path,
        showName: file.showName,
        showId: file.showId ?? tmdbShowId,
        seasonNumber: file.seasonNumber,
        episodeNumber: file.episodeNumber,
        posterPath: file.posterPath,
      );

  if (!ref.read(isTmdbSignedInProvider)) return;

  final accountService = ref.read(tmdbAccountServiceProvider);
  final session = ref.read(tmdbSessionProvider);
  if (session == null) return;

  final showId =
      file.showId ?? tmdbShowId ?? await _resolveShowId(ref, file.showName);
  final isEpisode =
      showId != null &&
      file.seasonNumber != null &&
      file.episodeNumber != null;

  try {
    if (isEpisode) {
      // Rate the specific episode — TMDB's only per-episode persistence.
      await accountService.rateEpisode(
        seriesId: showId,
        seasonNumber: file.seasonNumber!,
        episodeNumber: file.episodeNumber!,
        value: TmdbAccountService.watchedRatingValue,
      );
    } else if (tmdbMovieId != null) {
      // Movie: rate it AND drop it from the watchlist.
      await Future.wait([
        accountService.rateMovie(
          movieId: tmdbMovieId,
          value: TmdbAccountService.watchedRatingValue,
        ),
        accountService.setWatchlist(
          accountId: session.accountId,
          mediaType: TmdbMediaType.movie,
          mediaId: tmdbMovieId,
          watchlist: false,
        ),
      ]);
    } else if (showId != null && file.seasonNumber == null) {
      // Whole-show entry (no season/episode metadata): rate the show AND
      // drop it from the watchlist.
      await Future.wait([
        accountService.rateShow(
          seriesId: showId,
          value: TmdbAccountService.watchedRatingValue,
        ),
        accountService.setWatchlist(
          accountId: session.accountId,
          mediaType: TmdbMediaType.tv,
          mediaId: showId,
          watchlist: false,
        ),
      ]);
    }
  } catch (e) {
    debugPrint('[LibraryActions] TMDB watched-sync push failed: $e');
  }
}

/// Reverse of [markAsWatched]. Mirrors the push paths in [markAsWatched]:
/// - Local: clears `isCompleted`.
/// - TMDB: DELETEs the rating that was used as the "watched" proxy. We do
///   NOT re-add to the watchlist here — that's user intent that should be
///   explicit, not inferred from un-marking watched.
Future<void> markAsNotWatched(
  WidgetRef ref,
  LocalMediaFile file, {
  int? tmdbMovieId,
  int? tmdbShowId,
}) async {
  await ref.read(watchProgressProvider.notifier).markNotCompleted(file.path);

  if (!ref.read(isTmdbSignedInProvider)) return;

  final accountService = ref.read(tmdbAccountServiceProvider);
  final session = ref.read(tmdbSessionProvider);
  if (session == null) return;

  final showId =
      file.showId ?? tmdbShowId ?? await _resolveShowId(ref, file.showName);
  final isEpisode =
      showId != null &&
      file.seasonNumber != null &&
      file.episodeNumber != null;

  try {
    if (isEpisode) {
      await accountService.deleteEpisodeRating(
        seriesId: showId,
        seasonNumber: file.seasonNumber!,
        episodeNumber: file.episodeNumber!,
      );
    } else if (tmdbMovieId != null) {
      await accountService.deleteMovieRating(movieId: tmdbMovieId);
    } else if (showId != null && file.seasonNumber == null) {
      await accountService.deleteShowRating(seriesId: showId);
    }
  } catch (e) {
    debugPrint('[LibraryActions] TMDB watched-sync delete failed: $e');
  }
}

/// Bidirectional reconcile between local watched state and TMDB ratings.
/// Triggered on:
///   - app launch (`MainNavigationScreen.initState`)
///   - library refresh
///   - Settings → TMDB Account → "Refresh from TMDB"
///   - sign-in completion (after the OAuth flow lands)
///
/// Strategy mirrors the favorites/watchlist sync at
/// [FavoritesNotifier.syncFromTmdb]: **push-first, then TMDB-wins**.
///
///   1. PUSH local-completed episodes that aren't yet rated on TMDB →
///      `POST rating=10`. Guarantees no pre-existing local data is lost.
///      Best-effort: failed pushes are tracked so step 3 won't clobber
///      them locally.
///   2. After push, TMDB has the union of (local-watched ∪ remote-rated).
///   3. PULL with TMDB as authority: for every visible local file —
///      - rating present on TMDB → mark watched locally (if not already)
///      - rating absent on TMDB → unmark watched locally (if was)
///
/// The unmark step in (3) is what makes "TMDB wins": if you unwatched
/// an episode on another device (which DELETEs the rating), this device
/// follows on the next reconcile. To avoid clobbering on transient
/// network failure, push failures are treated as "present" so step 3
/// preserves the local mark until the next successful push.
Future<void> reconcileWatchedWithTmdb(
  WidgetRef ref, {
  bool pushLocalFirst = false,
}) async {
  if (!ref.read(isTmdbSignedInProvider)) return;
  final session = ref.read(tmdbSessionProvider);
  if (session == null) return;
  final accountService = ref.read(tmdbAccountServiceProvider);

  try {
    final ratedEpisodes = await accountService.getRatedEpisodes(
      accountId: session.accountId,
    );
    String keyFor(int s, int se, int ep) => '$s/$se/$ep';
    // Mutable working set — starts as the truth from TMDB; may be
    // augmented by [pushLocalFirst] union below.
    final ratedKeys = <String>{
      for (final e in ratedEpisodes)
        keyFor(e.showId, e.seasonNumber, e.episodeNumber),
    };

    final progressMap = ref.read(watchProgressProvider);
    final progressNotifier = ref.read(watchProgressProvider.notifier);

    // ── 1. (Optional) PUSH local-watched not on TMDB → POST ─────────
    // Only on sign-in (`pushLocalFirst: true`). Ongoing reconciles
    // skip this so remote deletes propagate — if we pushed local
    // every time, an unmark on another device would be reversed.
    if (pushLocalFirst) {
      for (final p in progressMap.values) {
        if (!p.isCompleted) continue;
        final season = p.seasonNumber;
        final episode = p.episodeNumber;
        if (season == null || episode == null) continue;
        final showId = p.showId ?? await _resolveShowId(ref, p.showName);
        if (showId == null) continue;
        final k = keyFor(showId, season, episode);
        if (ratedKeys.contains(k)) continue;
        try {
          await accountService.rateEpisode(
            seriesId: showId,
            seasonNumber: season,
            episodeNumber: episode,
            value: TmdbAccountService.watchedRatingValue,
          );
          ratedKeys.add(k);
        } catch (e) {
          debugPrint(
            '[reconcile] push failed for $showId S${season}E$episode: $e',
          );
          // Treat as present so the pull step below doesn't clobber
          // local on a transient failure. Next reconcile retries.
          ratedKeys.add(k);
        }
      }
    }

    // ── 2 + 3. TMDB-wins pull ────────────────────────────────────────
    // Build the union of "things to reconcile": every visible local file
    // PLUS every watch_progress entry (so orphaned watched marks — files
    // that have been deleted — still follow remote unmarks).
    final files = ref.read(localMediaFilesProvider).value ?? [];
    final filesByPath = {for (final f in files) f.path: f};

    final unionPaths = <String>{
      ...filesByPath.keys,
      for (final p in progressMap.values) p.filePath,
    };

    for (final path in unionPaths) {
      final file = filesByPath[path];
      final existing = progressMap[WatchProgress.generateHash(path)];

      // Episode metadata: prefer the local file (parsed from filename
      // at scan time), fall back to the persisted progress entry.
      final season = file?.seasonNumber ?? existing?.seasonNumber;
      final episode = file?.episodeNumber ?? existing?.episodeNumber;
      if (season == null || episode == null) continue;

      final showName = file?.showName ?? existing?.showName;
      final showId =
          file?.showId ?? existing?.showId ?? await _resolveShowId(ref, showName);
      if (showId == null) continue;

      final ratedOnTmdb = ratedKeys.contains(keyFor(showId, season, episode));
      final localWatched = existing?.isCompleted == true;

      if (ratedOnTmdb && !localWatched) {
        await progressNotifier.markCompleted(
          path,
          showName: showName,
          showId: showId,
          seasonNumber: season,
          episodeNumber: episode,
          posterPath: file?.posterPath ?? existing?.posterPath,
        );
      } else if (!ratedOnTmdb && localWatched) {
        // TMDB says not watched — another device unwatched it. Follow.
        await progressNotifier.markNotCompleted(path);
      }
    }
  } catch (e) {
    debugPrint('[LibraryActions] TMDB watched reconcile failed: $e');
  }
}

