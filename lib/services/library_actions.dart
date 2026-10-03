import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../models/local_media_file.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/watch_progress.dart';
import '../providers/connection_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/tmdb_synced_ids.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../utils/constants.dart';
import '../utils/platform_utils.dart';
import 'app_logger.dart';
import 'tmdb_watched_sync.dart';
import 'torrent_engine.dart';

// ---------------------------------------------------------------------------
// Which torrent a library file belongs to
// ---------------------------------------------------------------------------

/// A library file's place in one torrent.
@visibleForTesting
class TorrentFileMatch {
  const TorrentFileMatch({
    required this.torrent,
    required this.entry,
    required this.files,
  });

  final Torrent torrent;

  /// The torrent's entry for the file.
  final TorrentFile entry;

  /// Every file in the torrent, [entry] included.
  final List<TorrentFile> files;
}

/// The outcome of asking the engine which torrent wrote a file.
@visibleForTesting
class TorrentFileLookup {
  const TorrentFileLookup(this.match, {this.uncertain = false});

  /// The torrent that lists the file, or null when none does.
  final TorrentFileMatch? match;

  /// A torrent that plausibly owns the file could not be checked — its
  /// file list failed to load or came back empty. With no [match], the
  /// answer is "don't know", not "no torrent".
  final bool uncertain;
}

/// Where [torrent] puts [entry] on disk.
///
/// Both engines report file names relative to the save path: qBittorrent's
/// include the torrent's root folder, and rqbit's `output_folder` (its save
/// path) is already that folder. Names may use either separator — a
/// qBittorrent on Windows sends `Season 01\Episode.mkv`.
@visibleForTesting
String torrentFilePath(Torrent torrent, TorrentFile entry, {p.Context? path}) {
  final ctx = path ?? p.context;
  final segments = entry.name
      .split(RegExp(r'[\\/]'))
      .where((s) => s.isNotEmpty);
  return ctx.normalize(ctx.joinAll([torrent.savePath, ...segments]));
}

/// Whether [entry] of [torrent] (which has [fileCount] files) is the file
/// at [filePath].
///
/// Exact path equality — never a prefix. The prefix test this replaced
/// (`filePath.startsWith(contentPath)`) was the data-loss bug: rqbit puts a
/// single-file torrent straight into the download folder and reports that
/// folder as its content path, so *every* file in the library "belonged" to
/// whichever such torrent came first, and deleting library file B removed
/// torrent A and its files. Case-insensitive where the filesystem is
/// (`p.windows`).
@visibleForTesting
bool torrentFileIs(
  Torrent torrent,
  TorrentFile entry,
  int fileCount,
  String filePath, {
  p.Context? path,
}) {
  final ctx = path ?? p.context;
  if (torrent.savePath.isNotEmpty &&
      ctx.equals(torrentFilePath(torrent, entry, path: ctx), filePath)) {
    return true;
  }
  // qBittorrent's content path *is* the file for a single-file torrent, and
  // stays right when the save path has been remapped.
  return fileCount == 1 &&
      torrent.contentPath.isNotEmpty &&
      ctx.equals(torrent.contentPath, filePath);
}

/// The torrents worth asking about [filePath], most likely owner first:
/// the file's own [hintHash], one whose content path is the file, one named
/// after it, then any whose folder holds it. A torrent saving somewhere else
/// entirely is not a candidate at all.
///
/// `strong` marks the likely owners — for those, an empty or failed file
/// list makes the answer uncertain rather than "not this one".
@visibleForTesting
List<({Torrent torrent, bool strong})> candidateTorrentsFor(
  List<Torrent> torrents,
  String filePath, {
  String? hintHash,
  p.Context? path,
}) {
  final ctx = path ?? p.context;
  final baseName = basenameOf(filePath).toLowerCase();
  final ranked = <({int rank, Torrent torrent})>[];
  for (final t in torrents) {
    final inSaveFolder =
        t.savePath.isNotEmpty && ctx.isWithin(t.savePath, filePath);
    final inContentFolder =
        t.contentPath.isNotEmpty && ctx.isWithin(t.contentPath, filePath);
    final int rank;
    if (hintHash != null && hintHash.isNotEmpty && t.hash == hintHash) {
      rank = 0;
    } else if (t.contentPath.isNotEmpty &&
        ctx.equals(t.contentPath, filePath)) {
      rank = 1;
    } else if ((inSaveFolder || inContentFolder) &&
        t.name.toLowerCase() == baseName) {
      rank = 2;
    } else if (inContentFolder) {
      rank = 3;
    } else if (inSaveFolder) {
      rank = 4;
    } else {
      continue;
    }
    ranked.add((rank: rank, torrent: t));
  }
  ranked.sort((a, b) => a.rank.compareTo(b.rank));
  return [for (final r in ranked) (torrent: r.torrent, strong: r.rank <= 2)];
}

/// Ask [engine] which of [torrents] wrote [file], by each candidate's own
/// file list — see [torrentFileIs].
@visibleForTesting
Future<TorrentFileLookup> findTorrentForFile({
  required TorrentEngine engine,
  required List<Torrent> torrents,
  required LocalMediaFile file,
  p.Context? path,
}) async {
  var uncertain = false;
  for (final candidate in candidateTorrentsFor(
    torrents,
    file.path,
    hintHash: file.torrentHash,
    path: path,
  )) {
    final t = candidate.torrent;
    List<TorrentFile> files;
    try {
      files = await engine.getTorrentFiles(t.hash);
    } catch (e) {
      AppLog.w('[LibraryActions] file list for ${t.hash} failed: $e');
      files = const [];
    }
    if (files.isEmpty) {
      // A torrent always has files once its metadata is in. Both engines
      // answer an error with an empty list, so for a likely owner this is a
      // lookup that failed, not a torrent that owns nothing.
      if (candidate.strong) uncertain = true;
      continue;
    }
    for (final entry in files) {
      if (torrentFileIs(t, entry, files.length, file.path, path: path)) {
        return TorrentFileLookup(
          TorrentFileMatch(torrent: t, entry: entry, files: files),
        );
      }
    }
  }
  return TorrentFileLookup(null, uncertain: uncertain);
}

/// Whether [match]'s torrent holds other episodes worth keeping — a season
/// pack, as opposed to one episode with its subtitles, sample and NFO.
///
/// "Worth keeping" is a video of real size that is still selected or already
/// finished. A pack trimmed down to this one episode (how auto-download
/// grabs from a pack) has nothing else wanted, so it can go whole.
@visibleForTesting
bool torrentHoldsOtherEpisodes(TorrentFileMatch match) {
  for (final f in match.files) {
    if (f.index == match.entry.index) continue;
    if (!videoExtensions.contains(f.extension)) continue;
    if (f.size < minPlayableBytes) continue;
    if (f.fileName.toLowerCase().contains('sample')) continue;
    if (f.priority > 0 || f.isComplete) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Completeness
// ---------------------------------------------------------------------------

/// Whether a local file is genuinely finished, rather than a pre-allocated
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
/// So the engine is asked about the file's actual progress:
///   * no torrent lists this exact file → nothing is writing to it; trust
///     the disk (an imported or long-finished file);
///   * a torrent lists it → require every byte ([TorrentFile.isComplete]);
///   * a likely owner could not be checked → answer no. Being sent to the
///     source picker for a file you already have is a minor annoyance; being
///     handed a file of zeros is a broken player with no error.
Future<bool> isFileCompleteOnDisk(WidgetRef ref, LocalMediaFile file) async {
  // Everything the check needs, read before the first await: the screen
  // that asked may be gone by the time the engine answers.
  final engine = ref.read(torrentEngineProvider);
  final torrents = ref.read(torrentListProvider).torrents;

  final name = basenameOf(file.path);
  final onDisk = File(file.path);
  if (!await onDisk.exists()) {
    AppLog.d('[Completeness] "$name" — not on disk');
    return false;
  }

  // Size first, because percentages lie about empty files: a 0-byte entry is
  // "100% downloaded" by every measure an engine reports, having 0 of 0
  // bytes. Several public packs ship zero-byte placeholders, and trusting the
  // percentage on one sends an empty file straight to the player.
  final size = await onDisk.length();
  if (size < minPlayableBytes) {
    AppLog.d('[Completeness] "$name" — only $size bytes on disk');
    return false;
  }

  final lookup = await findTorrentForFile(
    engine: engine,
    torrents: torrents,
    file: file,
  );
  final match = lookup.match;
  if (match == null) {
    if (lookup.uncertain) {
      AppLog.w('[Completeness] "$name" — its torrent could not be checked');
      return false;
    }
    AppLog.d('[Completeness] "$name" — no torrent lists it, trusting disk');
    return true;
  }

  final complete = match.entry.isComplete;
  AppLog.d(
    '[Completeness] "$name" — torrent ${match.torrent.hash} says '
    '${(match.entry.progress * 100).toStringAsFixed(1)}% → '
    '${complete ? "playable" : "INCOMPLETE, must stream"}',
  );
  return complete;
}

// ---------------------------------------------------------------------------
// Delete
// ---------------------------------------------------------------------------

/// What deleting a library file takes with it — for wording the confirmation
/// before it happens.
enum LibraryDeleteScope {
  /// The file's torrent goes too: it holds nothing else worth keeping.
  wholeTorrent,

  /// The file is one episode of a season pack. Only it is deleted; the
  /// engine stops fetching it and the rest of the pack stays in Transfers.
  fileInPack,

  /// No torrent wrote it (or none could be found). Just the file.
  fileOnly,
}

/// Outcome of a delete action — lets the UI surface a useful toast.
class LibraryDeleteResult {
  final bool fileRemoved;
  final bool torrentRemoved;
  final String? error;

  /// What the delete set out to remove, when it got far enough to know.
  final LibraryDeleteScope? scope;

  const LibraryDeleteResult({
    required this.fileRemoved,
    required this.torrentRemoved,
    this.error,
    this.scope,
  });

  bool get success => fileRemoved || torrentRemoved;
}

LibraryDeleteScope _scopeFor(TorrentFileMatch? match) {
  if (match == null) return LibraryDeleteScope.fileOnly;
  return torrentHoldsOtherEpisodes(match)
      ? LibraryDeleteScope.fileInPack
      : LibraryDeleteScope.wholeTorrent;
}

/// What [deleteLibraryItem] would remove for [file], without removing
/// anything. Asks the engine, so it takes a moment; a lookup that fails
/// plans a plain file delete, which is also what the delete then does.
Future<LibraryDeleteScope> planLibraryDelete(
  WidgetRef ref,
  LocalMediaFile file,
) async {
  final engine = ref.read(torrentEngineProvider);
  final torrents = ref.read(torrentListProvider).torrents;
  final lookup = await findTorrentForFile(
    engine: engine,
    torrents: torrents,
    file: file,
  );
  return _scopeFor(lookup.match);
}

/// Turn a failed delete into something a user can act on.
///
/// The raw `FileSystemException` reads `OSError: The process cannot access
/// the file because it is being used by another process, errno = 32`, which
/// is both alarming and unhelpful. Windows is where it actually happens:
/// unlike macOS and Linux, it refuses to unlink a file that another process
/// holds open, and the engine holds every file it is still seeding. The
/// answer is always the same — stop the torrent first — so say that instead.
@visibleForTesting
String describeDeleteFailure(Object error) {
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    // 32 ERROR_SHARING_VIOLATION, 33 ERROR_LOCK_VIOLATION (Windows);
    // EACCES / EPERM elsewhere.
    if (code == 32 || code == 33) {
      return 'the file is still in use — stop the torrent and try again';
    }
    if (code == 5 || code == 13 || code == 1) {
      return 'permission denied';
    }
    final message = error.osError?.message ?? error.message;
    return message.isEmpty ? 'could not delete the file' : message;
  }
  return 'could not delete the file';
}

/// Delete a library item, and exactly as much of its torrent as belongs to
/// it — see [LibraryDeleteScope]:
///
/// - **whole torrent**: the engine deletes the torrent with its files. It
///   handles files it still holds open more reliably than racing it would.
///   If it refuses, the file is deleted directly and the torrent stays.
/// - **one episode of a pack**: the engine is told to stop fetching that
///   file, then the file alone is deleted. If the engine will not deselect
///   it, nothing is deleted — removing a file the torrent still wants only
///   makes it download again.
/// - **no torrent**: a direct filesystem delete.
///
/// Then the library is rescanned and stale watch progress swept.
Future<LibraryDeleteResult> deleteLibraryItem(
  WidgetRef ref,
  LocalMediaFile file,
) async {
  // Read up front: this outlives the confirmation dialog, and possibly the
  // screen behind it — a WidgetRef throws once its widget is gone.
  final container = ProviderScope.containerOf(ref.context, listen: false);
  final engine = ref.read(torrentEngineProvider);
  final torrentList = ref.read(torrentListProvider.notifier);
  final torrents = ref.read(torrentListProvider).torrents;
  final progress = ref.read(watchProgressProvider.notifier);

  final lookup = await findTorrentForFile(
    engine: engine,
    torrents: torrents,
    file: file,
  );
  final match = lookup.match;
  final scope = _scopeFor(match);

  if (match != null && scope == LibraryDeleteScope.wholeTorrent) {
    final hash = match.torrent.hash;
    try {
      final res = await torrentList.deleteTorrents([hash], deleteFiles: true);
      if (res.success) {
        // The torrent delete refreshes the library and sweeps stale watch
        // progress itself (TorrentListNotifier.deleteTorrents).
        return LibraryDeleteResult(
          fileRemoved: true,
          torrentRemoved: true,
          scope: scope,
        );
      }
    } catch (e) {
      AppLog.e('[LibraryActions] engine delete failed for $hash: $e');
    }
    // The engine refused: delete the file directly below. The torrent stays.
  } else if (match != null && scope == LibraryDeleteScope.fileInPack) {
    var deselected = false;
    try {
      deselected = await engine.setFilePriority(match.torrent.hash, [
        match.entry.index,
      ], FilePriority.doNotDownload.value);
    } catch (e) {
      AppLog.e('[LibraryActions] could not deselect ${file.path}: $e');
    }
    if (!deselected) {
      return LibraryDeleteResult(
        fileRemoved: false,
        torrentRemoved: false,
        scope: scope,
        error:
            "couldn't take this episode out of its season pack — try again, "
            'or delete the whole pack from Transfers',
      );
    }
  } else if (lookup.uncertain) {
    AppLog.w(
      '[LibraryActions] ${file.path}: its torrent could not be checked, '
      'deleting the file only',
    );
  }

  // Direct filesystem delete.
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
      scope: scope,
      error: describeDeleteFailure(e),
    );
  }

  // Bookkeeping, in its own guard. The unlink has already happened by here,
  // so folding a failure of this step into the delete result reported
  // "nothing was removed" about a file that was in fact gone — the toast
  // said the delete failed and the row disappeared anyway.
  try {
    // [refreshLocalMedia], through the container: the widget may be gone.
    container.invalidate(localMediaScannerProvider);
    await progress.cleanupStaleEntries();
  } catch (e) {
    AppLog.w(
      '[LibraryActions] post-delete cleanup failed for ${file.path}: $e',
    );
  }
  return LibraryDeleteResult(
    fileRemoved: true,
    torrentRemoved: false,
    scope: scope,
  );
}

// ---------------------------------------------------------------------------
// Watched marks
// ---------------------------------------------------------------------------

/// Mark a library item as watched.
///
/// Bidirectional with TMDB, which has no "watched" flag: a 10/10 rating is
/// the proxy, per episode, show or movie (see [TmdbWatchedSync.push]).
/// Movies and whole shows also leave the watchlist.
///
/// The local mark is made first and is what the UI shows. While signed in it
/// is flagged [WatchProgress.tmdbPushPending] until TMDB confirms, so a mark
/// made offline is pushed by the next reconcile instead of being erased by
/// it. A title TMDB cannot identify unambiguously is never written there —
/// rating whichever "Halloween" ranks first is worse than rating none.
Future<void> markAsWatched(
  WidgetRef ref,
  LocalMediaFile file, {
  int? tmdbMovieId,
  int? tmdbShowId,
}) async {
  final notifier = ref.read(watchProgressProvider.notifier);
  final sync = ref.read(tmdbWatchedSyncProvider);

  // Resolve up-front so the local row carries the structured key (show /
  // movie id): reconcile and the UI matchers use it directly on later
  // passes instead of re-resolving from the filename.
  final (:target, :resolveFailed) = await _resolveWatchedTarget(
    sync,
    file,
    showId: file.showId ?? tmdbShowId,
    movieId: tmdbMovieId,
  );

  // Forward enough metadata that the notifier can synthesise a fresh row if
  // none exists yet (the common case for items downloaded but never opened).
  await notifier.markCompleted(
    file.path,
    showName: file.showName,
    showId: switch (target) {
      EpisodeTarget(:final showId) || ShowTarget(:final showId) => showId,
      _ => file.showId ?? tmdbShowId,
    },
    seasonNumber: file.seasonNumber,
    episodeNumber: file.episodeNumber,
    movieId: switch (target) {
      MovieTarget(:final movieId) => movieId,
      _ =>
        file.seasonNumber != null && file.episodeNumber != null
            ? null
            : tmdbMovieId,
    },
    posterPath: file.posterPath,
    tmdbPushPending: sync != null && (resolveFailed || target != null),
  );

  if (sync == null || target == null) return;
  await _pushMark(notifier, sync, file.path, target, watched: true);
}

/// Reverse of [markAsWatched]: clears the local mark and deletes the TMDB
/// rating that stood for it. The watchlist is left alone — re-adding there
/// is user intent that should be explicit, not inferred from un-marking.
Future<void> markAsNotWatched(
  WidgetRef ref,
  LocalMediaFile file, {
  int? tmdbMovieId,
  int? tmdbShowId,
}) async {
  final notifier = ref.read(watchProgressProvider.notifier);
  final sync = ref.read(tmdbWatchedSyncProvider);
  // Prefer ids an earlier mark or reconcile persisted on the row.
  final existing = notifier.getProgress(file.path);

  final (:target, :resolveFailed) = await _resolveWatchedTarget(
    sync,
    file,
    showId: file.showId ?? existing?.showId ?? tmdbShowId,
    movieId: tmdbMovieId ?? existing?.movieId,
  );

  await notifier.markNotCompleted(
    file.path,
    tmdbPushPending: sync != null && (resolveFailed || target != null),
  );

  if (sync == null || target == null) return;
  await _pushMark(notifier, sync, file.path, target, watched: false);
}

/// What TMDB calls [file], or null — with whether that was a failure to ask
/// (offline, TMDB down) rather than a title TMDB can't place, since only the
/// former should leave the mark pending for the next reconcile.
Future<({WatchedTarget? target, bool resolveFailed})> _resolveWatchedTarget(
  TmdbWatchedSync? sync,
  LocalMediaFile file, {
  int? showId,
  int? movieId,
}) async {
  if (sync == null) return (target: null, resolveFailed: false);
  final isEpisodeFile = file.seasonNumber != null && file.episodeNumber != null;
  try {
    final target = await sync.targetFor(
      path: file.path,
      showName: file.showName,
      season: file.seasonNumber,
      episode: file.episodeNumber,
      showId: showId,
      movieId: isEpisodeFile ? null : movieId,
    );
    return (target: target, resolveFailed: false);
  } catch (e) {
    AppLog.w('[LibraryActions] could not identify ${file.fileName}: $e');
    return (target: null, resolveFailed: true);
  }
}

/// Push one mark; clear its pending flag only if TMDB took it.
Future<void> _pushMark(
  WatchProgressNotifier notifier,
  TmdbWatchedSync sync,
  String path,
  WatchedTarget target, {
  required bool watched,
}) async {
  try {
    await sync.push(target, watched: watched);
  } catch (e) {
    AppLog.w('[LibraryActions] TMDB watched push failed for $path: $e');
    return; // Still pending — the next reconcile retries it.
  }
  await notifier.settleTmdbPush({path: watched});
}

// ---------------------------------------------------------------------------
// Reconcile
// ---------------------------------------------------------------------------

/// A reconcile already running, so overlapping triggers (launch, sign-in,
/// library refresh, Settings) share it instead of interleaving their writes.
Future<TmdbSyncResult>? _reconcileInFlight;

/// Bidirectional reconcile between local watched state and TMDB ratings.
/// Triggered on:
///   - app launch (`MainNavigationScreen.initState`)
///   - library refresh
///   - Settings → TMDB Account → "Refresh from TMDB"
///   - sign-in completion (after the OAuth flow lands)
///
/// In three steps — fetch, push, then pull — with the decisions in the pure
/// [planWatchedReconcile]:
///
///   1. **Fetch** TMDB's rated episodes and movies.
///   2. **Push** what TMDB has not heard about: every row flagged
///      [WatchProgress.tmdbPushPending] (a mark made offline, or whose
///      write failed), and — on sign-in ([pushLocalFirst]) — every local
///      watched mark TMDB lacks, so nothing local is lost to step 3. A push
///      that fails stays pending.
///   3. **Pull**, TMDB winning: rated → watched here; not rated → an
///      explicit mark follows it (one played to the credits never does, and
///      a pending one is left until it has been pushed). Applied as one
///      write, and none at all when nothing changed.
///
/// Never throws. The result says whether TMDB could be read — a refresh that
/// silently did nothing offline used to look like it had worked — and how
/// many marks are still waiting to reach TMDB.
Future<TmdbSyncResult> reconcileWatchedWithTmdb(
  WidgetRef ref, {
  bool pushLocalFirst = false,
}) async {
  final sync = ref.read(tmdbWatchedSyncProvider);
  if (sync == null) return const TmdbSyncResult(TmdbSyncOutcome.signedOut);
  // A container, not the WidgetRef: this is many network round trips long,
  // and the screen that started it (Settings, after sign-in) can close in
  // the middle. A WidgetRef throws once its widget is gone.
  final container = ProviderScope.containerOf(ref.context, listen: false);

  final previous = _reconcileInFlight;
  if (previous != null) {
    final result = await previous;
    // The run that just finished already did the pull; only a sign-in
    // union needs its own pass.
    if (!pushLocalFirst) return result;
  }
  final run = _reconcile(container, sync, pushLocalFirst: pushLocalFirst);
  _reconcileInFlight = run;
  try {
    return await run;
  } finally {
    if (identical(_reconcileInFlight, run)) _reconcileInFlight = null;
  }
}

Future<TmdbSyncResult> _reconcile(
  ProviderContainer container,
  TmdbWatchedSync sync, {
  required bool pushLocalFirst,
}) async {
  final notifier = container.read(watchProgressProvider.notifier);
  try {
    // ── 1. Fetch ──────────────────────────────────────────────────────
    final ratedEpisodes = [
      for (final e in await sync.account.getRatedEpisodes(
        accountId: sync.accountId,
      ))
        (showId: e.showId, season: e.seasonNumber, episode: e.episodeNumber),
    ];
    final ratedMovies = await sync.account.getRatedMovieIds(
      accountId: sync.accountId,
    );

    // ── 2. Push ───────────────────────────────────────────────────────
    final snapshot = container.read(watchProgressProvider);
    final settled = <String, bool>{};
    final nowPending = <String>{};
    for (final row in snapshot.values) {
      final pending = row.tmdbPushPending;
      final union = pushLocalFirst && !pending && row.isEffectivelyWatched;
      if (!pending && !union) continue;

      final WatchedTarget? target;
      try {
        target = await sync.targetFor(
          path: row.filePath,
          showName: row.showName,
          season: row.seasonNumber,
          episode: row.episodeNumber,
          showId: row.showId,
          movieId: row.movieId,
        );
      } catch (e) {
        if (union) nowPending.add(row.filePath);
        continue; // TMDB unreachable — stays (or becomes) pending.
      }
      final watched = row.isEffectivelyWatched;
      if (target == null) {
        // Nothing on TMDB to push to, and never will be: a pending flag
        // would only stop this row from ever following TMDB.
        if (pending) settled[row.filePath] = watched;
        continue;
      }
      if (union && _alreadyRated(target, ratedEpisodes, ratedMovies)) {
        continue;
      }
      try {
        await sync.push(target, watched: watched);
        settled[row.filePath] = watched;
        _recordPush(target, watched, ratedEpisodes, ratedMovies);
      } catch (e) {
        AppLog.w('[LibraryActions] push failed for ${row.filePath}: $e');
        if (union) nowPending.add(row.filePath);
      }
    }
    if (settled.isNotEmpty || nowPending.isNotEmpty) {
      await notifier.settleTmdbPush(settled, markPending: nowPending);
    }

    // ── 3. Pull ───────────────────────────────────────────────────────
    final progress = container.read(watchProgressProvider);
    final files = container.read(localMediaFilesProvider).value ?? const [];
    final ids = await _resolveIds(sync, progress, files);
    // No await from here to the write: the plan is applied to the exact
    // state it was computed from.
    final plan = planWatchedReconcile(
      progress: container.read(watchProgressProvider),
      files: files,
      ratedEpisodes: ratedEpisodes,
      ratedMovieIds: ratedMovies,
      resolvedShowIds: ids.shows,
      resolvedMovieIds: ids.movies,
    );
    await notifier.applyWatchedSync(plan);
    return TmdbSyncResult(
      TmdbSyncOutcome.synced,
      pendingChanges: container
          .read(watchProgressProvider)
          .values
          .where((r) => r.tmdbPushPending)
          .length,
    );
  } catch (e) {
    AppLog.e('[LibraryActions] TMDB watched reconcile failed: $e');
    return TmdbSyncResult(TmdbSyncOutcome.failed, error: e);
  }
}

bool _alreadyRated(
  WatchedTarget target,
  List<({int showId, int season, int episode})> episodes,
  Set<int> movies,
) => switch (target) {
  EpisodeTarget(:final showId, :final season, :final episode) =>
    episodes.contains((showId: showId, season: season, episode: episode)),
  MovieTarget(:final movieId) => movies.contains(movieId),
  // TMDB's rated-shows list is not read, so a show mark is always pushed.
  ShowTarget() => false,
};

/// Keep the fetched remote sets in step with a push that just succeeded.
void _recordPush(
  WatchedTarget target,
  bool watched,
  List<({int showId, int season, int episode})> episodes,
  Set<int> movies,
) {
  switch (target) {
    case EpisodeTarget(:final showId, :final season, :final episode):
      final key = (showId: showId, season: season, episode: episode);
      episodes.remove(key);
      if (watched) episodes.add(key);
    case MovieTarget(:final movieId):
      watched ? movies.add(movieId) : movies.remove(movieId);
    case ShowTarget():
      break;
  }
}

/// TMDB ids for library files and rows that do not store one, by path.
/// Titles that fail to resolve (offline, or ambiguous) are left out.
Future<({Map<String, int> shows, Map<String, int> movies})> _resolveIds(
  TmdbWatchedSync sync,
  Map<String, WatchProgress> progress,
  List<LocalMediaFile> files,
) async {
  final shows = <String, int>{};
  final movies = <String, int>{};
  final filesByPath = {for (final f in files) f.path: f};
  final paths = {
    ...filesByPath.keys,
    for (final r in progress.values) r.filePath,
  };
  for (final path in paths) {
    final file = filesByPath[path];
    final row = progress[WatchProgress.generateHash(path)];
    final season = file?.seasonNumber ?? row?.seasonNumber;
    final episode = file?.episodeNumber ?? row?.episodeNumber;
    final isEpisode = season != null && episode != null;
    if (isEpisode && (file?.showId ?? row?.showId) != null) continue;
    if (!isEpisode && (row?.movieId != null || row?.showId != null)) continue;
    if (!isEpisode && WatchProgress.isSyntheticPath(path)) continue;
    try {
      final target = await sync.targetFor(
        path: path,
        showName: file?.showName ?? row?.showName,
        season: season,
        episode: episode,
      );
      switch (target) {
        case EpisodeTarget(:final showId):
          shows[path] = showId;
        case MovieTarget(:final movieId):
          movies[path] = movieId;
        case ShowTarget() || null:
          break;
      }
    } catch (e) {
      AppLog.w('[LibraryActions] could not identify $path: $e');
    }
  }
  return (shows: shows, movies: movies);
}
