import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../models/watch_progress.dart';
import '../providers/connection_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../utils/media_names.dart';
import '../utils/platform_utils.dart';
import 'app_logger.dart';
import 'tmdb_account_service.dart';

/// Cache of show-name → TMDB show id so the watched-sync doesn't hit
/// `/search/tv` on every Mark watched / Mark not watched click.
///
/// A confirmed miss (TMDB answered, and had no match) is cached as null so
/// we don't retry it. A *failure* — network down, rate limited, 5xx — is
/// deliberately NOT cached: these maps live for the whole process, so
/// caching a transient failure meant that title could never resolve again
/// until the app restarted, and every watched-sync for it silently no-oped.
final Map<String, int?> _showIdCache = {};

/// Same idea as [_showIdCache] but for movies — `/search/movie`.
final Map<String, int?> _movieIdCache = {};

/// Look up a TMDB show id by name. Returns null on miss / network failure
/// (the local mark already succeeded, so a missing id just means we skip
/// the TMDB push for this item).
Future<int?> _resolveShowId(WidgetRef ref, String? showName) async {
  if (showName == null || showName.isEmpty) return null;
  if (_showIdCache.containsKey(showName)) return _showIdCache[showName];
  try {
    final shows = await ref.read(tmdbApiServiceProvider).searchShows(showName);
    final id = shows.isNotEmpty ? shows.first.id : null;
    // Only reached when TMDB actually answered — safe to remember.
    _showIdCache[showName] = id;
    return id;
  } catch (e) {
    AppLog.w('[LibraryActions] show id lookup failed for "$showName": $e');
    return null; // Not cached — retry on the next pass.
  }
}

/// Look up a TMDB movie id by name. Same cache-misses-not-failures rule as
/// [_resolveShowId]. Used by movie-watched sync + the reconcile push step
/// for `LocalMediaFile`s with no `seasonNumber`.
Future<int?> _resolveMovieId(WidgetRef ref, String? movieName) async {
  if (movieName == null || movieName.isEmpty) return null;
  if (_movieIdCache.containsKey(movieName)) return _movieIdCache[movieName];
  try {
    final movies = await ref
        .read(tmdbApiServiceProvider)
        .searchMovies(movieName);
    final id = movies.isNotEmpty ? movies.first.id : null;
    _movieIdCache[movieName] = id;
    return id;
  } catch (e) {
    AppLog.w('[LibraryActions] movie id lookup failed for "$movieName": $e');
    return null; // Not cached — retry on the next pass.
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

/// Whether a local file is genuinely finished, rather than a qBittorrent
/// shell.
///
/// **`File.existsSync()` cannot answer this.** qBittorrent pre-allocates the
/// full size up front and pads the un-downloaded remainder with zeros, so a
/// file that is 0.6% downloaded is present on disk *at its full length* and
/// looks identical to a finished one. Every "already have it locally, just
/// play it" shortcut that checked only for existence would hand mpv several
/// hundred MB of zeros — which fails as `Failed to recognize file format`
/// and leaves the player spinning with no explanation.
///
/// So we ask qBittorrent for the file's actual progress:
///   * no torrent covers this path → nothing is writing to it; trust the
///     disk (an imported or long-finished file);
///   * a torrent covers it → require the matching entry to be complete;
///   * the lookup failed → answer no. Being sent to the source picker for a
///     file you already have is a minor annoyance; being handed a file of
///     zeros is a broken player with no error.
Future<bool> isFileCompleteOnDisk(WidgetRef ref, LocalMediaFile file) async {
  final name = basenameOf(file.path);
  final onDisk = File(file.path);
  if (!onDisk.existsSync()) {
    AppLog.d('[Completeness] "$name" — not on disk');
    return false;
  }

  // Size first, because percentages lie about empty files: a 0-byte entry is
  // "100% downloaded" by every measure qBittorrent reports, having 0 of 0
  // bytes. Several public packs ship zero-byte placeholders, and trusting the
  // percentage on one sends an empty file straight to the player.
  if (onDisk.lengthSync() < minPlayableBytes) {
    AppLog.d(
      '[Completeness] "$name" — only ${onDisk.lengthSync()} bytes on disk, '
      'not real media',
    );
    return false;
  }

  final hash = _findTorrentHashForFile(ref, file);
  if (hash == null) {
    AppLog.d('[Completeness] "$name" — no torrent covers it, trusting disk');
    return true;
  }

  try {
    final files = await ref.read(qbApiServiceProvider).getTorrentFiles(hash);
    final target = name.toLowerCase();
    for (final f in files) {
      final entry = basenameOf(f.name).toLowerCase();
      if (entry == target) {
        final complete = f.progress >= 0.999;
        AppLog.d(
          '[Completeness] "$name" — torrent says '
          '${(f.progress * 100).toStringAsFixed(1)}% → '
          '${complete ? "playable" : "INCOMPLETE, must stream"}',
        );
        return complete;
      }
    }
    // The torrent doesn't list this file — it isn't the one writing to it.
    AppLog.d('[Completeness] "$name" — not in torrent $hash, trusting disk');
    return true;
  } catch (e) {
    AppLog.w('[Completeness] "$name" — check failed for $hash: $e');
    return false;
  }
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
      final res = await ref.read(torrentListProvider.notifier).deleteTorrents([
        hash,
      ], deleteFiles: true);
      if (res.success) {
        // Torrent delete already invalidates media providers + cleans stale
        // watch progress entries (see TorrentListNotifier.deleteTorrents).
        return const LibraryDeleteResult(
          fileRemoved: true,
          torrentRemoved: true,
        );
      }
    } catch (e) {
      AppLog.e('[LibraryActions] qBit delete failed for $hash: $e');
    }
    // qBit refused — fall through to direct file delete.
  }

  // Direct filesystem delete fallback.
  try {
    final f = File(file.path);
    if (await f.exists()) {
      await f.delete();
    }
  } catch (e) {
    AppLog.e('[LibraryActions] File delete failed for ${file.path}: $e');
    return LibraryDeleteResult(
      fileRemoved: false,
      torrentRemoved: false,
      error: e.toString(),
    );
  }

  // Bookkeeping, in its own guard. The unlink has already happened by here,
  // so folding a failure of this step into the delete result reported
  // "nothing was removed" about a file that was in fact gone — the toast
  // said the delete failed and the row disappeared anyway.
  try {
    ref.invalidate(localMediaStreamProvider);
    ref.invalidate(localMediaFilesProvider);
    await ref.read(watchProgressProvider.notifier).cleanupStaleEntries();
  } catch (e) {
    AppLog.w(
      '[LibraryActions] post-delete cleanup failed for ${file.path}: $e',
    );
  }
  return LibraryDeleteResult(fileRemoved: true, torrentRemoved: hash != null);
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
  // Resolve up-front so the local WatchProgress entry carries the
  // structured key (showId / movieId). That lets reconcile + UI
  // matchers use the id directly on subsequent passes instead of
  // re-resolving from the filename.
  final isEpisodeFile = file.seasonNumber != null && file.episodeNumber != null;
  int? resolvedShowId = file.showId ?? tmdbShowId;
  int? resolvedMovieId = tmdbMovieId;
  if (ref.read(isTmdbSignedInProvider)) {
    if (isEpisodeFile && resolvedShowId == null) {
      resolvedShowId = await _resolveShowId(ref, file.showName);
    } else if (!isEpisodeFile && resolvedMovieId == null) {
      // Movie path — resolve a movie id from a cleaned filename.
      final movieName = file.showName ?? cleanMediaTitle(file.fileName);
      resolvedMovieId = await _resolveMovieId(ref, movieName);
    }
  }

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
        showId: resolvedShowId,
        seasonNumber: file.seasonNumber,
        episodeNumber: file.episodeNumber,
        movieId: resolvedMovieId,
        posterPath: file.posterPath,
      );

  if (!ref.read(isTmdbSignedInProvider)) return;

  final accountService = ref.read(tmdbAccountServiceProvider);
  final session = ref.read(tmdbSessionProvider);
  if (session == null) return;

  try {
    if (isEpisodeFile && resolvedShowId != null) {
      // Rate the specific episode — TMDB's only per-episode persistence.
      await accountService.rateEpisode(
        seriesId: resolvedShowId,
        seasonNumber: file.seasonNumber!,
        episodeNumber: file.episodeNumber!,
        value: TmdbAccountService.watchedRatingValue,
      );
    } else if (!isEpisodeFile && resolvedMovieId != null) {
      // Movie: rate it AND drop it from the watchlist.
      await Future.wait([
        accountService.rateMovie(
          movieId: resolvedMovieId,
          value: TmdbAccountService.watchedRatingValue,
        ),
        accountService.setWatchlist(
          accountId: session.accountId,
          mediaType: TmdbMediaType.movie,
          mediaId: resolvedMovieId,
          watchlist: false,
        ),
      ]);
    } else if (resolvedShowId != null && file.seasonNumber == null) {
      // Whole-show entry (no season/episode metadata): rate the show AND
      // drop it from the watchlist. Reached only when the file looks
      // show-shaped but has no S/E (rare; auto-download grab folder).
      await Future.wait([
        accountService.rateShow(
          seriesId: resolvedShowId,
          value: TmdbAccountService.watchedRatingValue,
        ),
        accountService.setWatchlist(
          accountId: session.accountId,
          mediaType: TmdbMediaType.tv,
          mediaId: resolvedShowId,
          watchlist: false,
        ),
      ]);
    }
  } catch (e) {
    AppLog.e('[LibraryActions] TMDB watched-sync push failed: $e');
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
  // Prefer an id we already persisted on the WatchProgress entry — set
  // by an earlier markAsWatched or the reconcile push. Falls back to
  // the file's parsed showId / explicit caller id / on-the-fly resolve.
  final existing = ref.read(
    watchProgressProvider,
  )[WatchProgress.generateHash(file.path)];

  await ref.read(watchProgressProvider.notifier).markNotCompleted(file.path);

  if (!ref.read(isTmdbSignedInProvider)) return;

  final accountService = ref.read(tmdbAccountServiceProvider);
  final session = ref.read(tmdbSessionProvider);
  if (session == null) return;

  final isEpisodeFile = file.seasonNumber != null && file.episodeNumber != null;
  final showId = isEpisodeFile
      ? (file.showId ??
            existing?.showId ??
            tmdbShowId ??
            await _resolveShowId(ref, file.showName))
      : null;
  final movieId = !isEpisodeFile
      ? (tmdbMovieId ??
            existing?.movieId ??
            await _resolveMovieId(
              ref,
              file.showName ?? cleanMediaTitle(file.fileName),
            ))
      : null;

  try {
    if (isEpisodeFile && showId != null) {
      await accountService.deleteEpisodeRating(
        seriesId: showId,
        seasonNumber: file.seasonNumber!,
        episodeNumber: file.episodeNumber!,
      );
    } else if (!isEpisodeFile && movieId != null) {
      await accountService.deleteMovieRating(movieId: movieId);
    } else if (showId != null && file.seasonNumber == null) {
      await accountService.deleteShowRating(seriesId: showId);
    }
  } catch (e) {
    AppLog.e('[LibraryActions] TMDB watched-sync delete failed: $e');
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
        if (!p.isEffectivelyWatched) continue;
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
          AppLog.e(
            '[LibraryActions] push failed for $showId S${season}E$episode: $e',
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

    // Track which (showId, season, episode) keys we've already
    // covered so the synthetic-entry pass below knows what's missing.
    final coveredKeys = <String>{};

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
          file?.showId ??
          existing?.showId ??
          await _resolveShowId(ref, showName);
      if (showId == null) continue;

      final k = keyFor(showId, season, episode);
      coveredKeys.add(k);
      final ratedOnTmdb = ratedKeys.contains(k);
      final localWatched = existing?.isEffectivelyWatched == true;

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
        // Explicit marks follow a remote unwatch. Playback that reached
        // credits stays local — otherwise a 95% watch whose rating never
        // posted (no show id, failed POST) is wiped on every startup.
        if (existing!.followsRemoteUnwatch) {
          await progressNotifier.markNotCompleted(path);
        }
      }
    }

    // ── 4. Synthetic entries for TMDB-only ratings ──────────────────
    // An episode you watched + marked on another device, but never
    // downloaded here, has no local file and no WatchProgress entry,
    // so the loop above can't surface it. Create a synthetic entry
    // keyed on a fake path so the episodes drawer's watched check
    // finds it. The drawer matches by (showId, season, episode), not
    // by file path, so this works without touching drawer code.
    //
    // Synthetics are cleaned up on the next reconcile naturally: if
    // the TMDB rating gets deleted (e.g. user unmarks on another
    // device), the `!ratedOnTmdb && localWatched` branch above runs
    // for the synthetic's path and marks it not-completed.
    for (final ep in ratedEpisodes) {
      final k = keyFor(ep.showId, ep.seasonNumber, ep.episodeNumber);
      if (coveredKeys.contains(k)) continue;
      final syntheticPath =
          'tmdb:rated:${ep.showId}/${ep.seasonNumber}/${ep.episodeNumber}';
      await progressNotifier.markCompleted(
        syntheticPath,
        showId: ep.showId,
        seasonNumber: ep.seasonNumber,
        episodeNumber: ep.episodeNumber,
      );
    }

    // ── 5. Movies: same shape, simpler key ──────────────────────────
    // TMDB has separate /rated/movies and /rated/tv/episodes endpoints.
    // For movies we just need the movie id — no season/episode key.
    final ratedMovieIds = await accountService.getRatedMovieIds(
      accountId: session.accountId,
    );

    // Push step (sign-in only) for movies.
    if (pushLocalFirst) {
      for (final p in progressMap.values) {
        if (!p.isEffectivelyWatched) continue;
        if (p.seasonNumber != null || p.episodeNumber != null) continue;
        var movieId = p.movieId;
        if (movieId == null) {
          // Try to resolve from filename — same as the watch_screen
          // mark-watched path. Cached so we don't hit TMDB twice.
          final name = p.showName ?? cleanMediaTitle(basenameOf(p.filePath));
          movieId = await _resolveMovieId(ref, name);
        }
        if (movieId == null) continue;
        if (ratedMovieIds.contains(movieId)) continue;
        try {
          await accountService.rateMovie(
            movieId: movieId,
            value: TmdbAccountService.watchedRatingValue,
          );
          ratedMovieIds.add(movieId);
        } catch (e) {
          AppLog.e('[LibraryActions] movie push failed for $movieId: $e');
          ratedMovieIds.add(movieId);
        }
      }
    }

    // Pull step for movies: align every local movie file + orphan with TMDB.
    final coveredMovieIds = <int>{};
    for (final path in unionPaths) {
      final file = filesByPath[path];
      final existing = progressMap[WatchProgress.generateHash(path)];

      final isEpisode =
          (file?.seasonNumber ?? existing?.seasonNumber) != null ||
          (file?.episodeNumber ?? existing?.episodeNumber) != null;
      if (isEpisode) continue;
      // Skip watched-only synthetics — they have no file and no movie.
      if (WatchProgress.isSyntheticPath(path)) continue;

      var movieId = existing?.movieId;
      if (movieId == null) {
        final name =
            file?.showName ??
            existing?.showName ??
            cleanMediaTitle(file?.fileName ?? basenameOf(path));
        movieId = await _resolveMovieId(ref, name);
      }
      if (movieId == null) continue;
      coveredMovieIds.add(movieId);

      final ratedOnTmdb = ratedMovieIds.contains(movieId);
      final localWatched = existing?.isEffectivelyWatched == true;

      if (ratedOnTmdb && !localWatched) {
        await progressNotifier.markCompleted(
          path,
          showName: file?.showName ?? existing?.showName,
          movieId: movieId,
          posterPath: file?.posterPath ?? existing?.posterPath,
        );
      } else if (!ratedOnTmdb && localWatched) {
        if (existing!.followsRemoteUnwatch) {
          await progressNotifier.markNotCompleted(path);
        }
      }
    }

    // Synthetic entries for TMDB-rated movies not present locally.
    for (final id in ratedMovieIds) {
      if (coveredMovieIds.contains(id)) continue;
      await progressNotifier.markCompleted('tmdb:rated-movie:$id', movieId: id);
    }
  } catch (e) {
    AppLog.e('[LibraryActions] TMDB watched reconcile failed: $e');
  }
}
