import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../providers/local_media_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import 'tmdb_account_service.dart';

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
/// - Always sets `WatchProgress.isCompleted = true` for this file path, which
///   drives the checkmark badge in the UI.
/// - If the user is signed in to TMDB *and* we have a TMDB id, also removes
///   the matching movie/show from their TMDB watchlist (a "done" proxy —
///   TMDB v3 has no native per-episode watched endpoint).
/// - Episodes are tracked locally only — TMDB v3 cannot mark individual
///   episodes watched.
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
  await ref.read(watchProgressProvider.notifier).markCompleted(
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

  try {
    if (tmdbMovieId != null) {
      await accountService.setWatchlist(
        accountId: session.accountId,
        mediaType: TmdbMediaType.movie,
        mediaId: tmdbMovieId,
        watchlist: false,
      );
    } else if (tmdbShowId != null && file.seasonNumber == null) {
      // Only sync the *show* (not individual episodes) — TMDB v3 has no
      // episode-level state.
      await accountService.setWatchlist(
        accountId: session.accountId,
        mediaType: TmdbMediaType.tv,
        mediaId: tmdbShowId,
        watchlist: false,
      );
    }
  } catch (e) {
    debugPrint('[LibraryActions] TMDB watchlist sync failed: $e');
    // Local state already updated — TMDB failure is non-fatal.
  }
}

/// Reverse of [markAsWatched] — local only (TMDB v3 has no "mark unwatched"
/// concept beyond re-adding to the watchlist, which is too ambiguous to do
/// automatically).
Future<void> markAsNotWatched(WidgetRef ref, LocalMediaFile file) async {
  await ref.read(watchProgressProvider.notifier).markNotCompleted(file.path);
}
