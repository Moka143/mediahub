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

/// Pull TMDB rated items and mark matching local files watched. Additive
/// only — never demotes a locally-watched item to unwatched. Called on
/// library refresh so ratings made from other clients (TMDB web, another
/// device) propagate into the library.
Future<void> syncWatchedFromTmdb(WidgetRef ref) async {
  if (!ref.read(isTmdbSignedInProvider)) return;
  final session = ref.read(tmdbSessionProvider);
  if (session == null) return;
  final accountService = ref.read(tmdbAccountServiceProvider);

  try {
    final ratedEpisodes = await accountService.getRatedEpisodes(
      accountId: session.accountId,
    );
    if (ratedEpisodes.isEmpty) return;

    final files = ref.read(localMediaFilesProvider).value ?? [];
    final progressNotifier = ref.read(watchProgressProvider.notifier);
    final currentProgress = ref.read(watchProgressProvider);

    // Build (showId, season, episode) key set for O(1) lookup.
    String keyFor(int s, int se, int ep) => '$s/$se/$ep';
    final ratedKeys = <String>{
      for (final e in ratedEpisodes)
        keyFor(e.showId, e.seasonNumber, e.episodeNumber),
    };

    for (final file in files) {
      final season = file.seasonNumber;
      final episode = file.episodeNumber;
      if (season == null || episode == null) continue;
      // Files parsed from filenames usually lack a TMDB show id — resolve
      // by name (cached) so we can match against TMDB's rated list.
      final showId =
          file.showId ?? await _resolveShowId(ref, file.showName);
      if (showId == null) continue;
      if (!ratedKeys.contains(keyFor(showId, season, episode))) continue;

      // Already marked locally — skip the write.
      final existing = currentProgress[WatchProgress.generateHash(file.path)];
      if (existing?.isCompleted == true) continue;

      await progressNotifier.markCompleted(
        file.path,
        showName: file.showName,
        showId: showId,
        seasonNumber: season,
        episodeNumber: episode,
        posterPath: file.posterPath,
      );
    }
  } catch (e) {
    debugPrint('[LibraryActions] TMDB watched-sync pull failed: $e');
  }
}
