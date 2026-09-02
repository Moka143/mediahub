import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../models/watch_progress.dart';
import '../services/app_logger.dart';
import '../services/local_media_scanner.dart';
import '../services/tmdb_api_service.dart';
import 'settings_provider.dart';
import 'shows_provider.dart';
import 'watch_progress_provider.dart';

/// Provider for download save path from settings
final downloadPathProvider = Provider<String>((ref) {
  return ref.watch(settingsProvider).defaultSavePath;
});

/// In-flight and resolved poster lookups, keyed by the search name.
///
/// The **Future** is cached, not the resolved value, and that distinction is
/// the whole point. Riverpod 3 auto-disposes a family provider the moment
/// nothing watches it, and the library list churns constantly — the torrent
/// poll rebuilds it every 2 s while a download runs, and every watch-progress
/// write rebuilds it during playback. A lookup still in flight when its
/// provider was torn down was simply discarded, and the next build started
/// over. While the churn outpaced the TMDB round trip the poster never
/// resolved at all, which is why a freshly-added episode or movie would
/// sometimes sit on a blank gradient until things settled down.
///
/// Sharing the Future also collapses the duplicate requests two cards for the
/// same show would otherwise both fire.
///
/// A confirmed miss — TMDB answered and had nothing — resolves to null and
/// stays cached. A *failure* (network down, rate limited) removes its own
/// entry so the next rebuild retries; caching that would leave the card on a
/// flat gradient for the rest of the session with no way back.
final _showPosterRequests = <String, Future<String?>>{};

/// Same contract as [_showPosterRequests], for `/search/movie`.
final _moviePosterRequests = <String, Future<String?>>{};

/// Provider to lookup show poster from TMDB
final showPosterProvider = FutureProvider.family<String?, String>((
  ref,
  showName,
) {
  // Outlive the card that asked. Without this the request is cancelled the
  // moment the list rebuilds — see [_showPosterRequests].
  ref.keepAlive();
  return _showPosterRequests[showName] ??= _lookupShowPoster(ref, showName);
});

Future<String?> _lookupShowPoster(Ref ref, String showName) async {
  // Read before the first await, while the provider is certainly alive.
  final tmdb = ref.read(tmdbApiServiceProvider);
  try {
    final shows = await tmdb.searchShows(showName);
    final posterPath = shows.isNotEmpty ? shows.first.posterPath : null;
    return posterPath != null
        ? TmdbApiService.getPosterUrl(posterPath, size: 'w185')
        : null;
  } catch (e) {
    AppLog.w('[LocalMedia] show poster lookup failed for "$showName": $e');
    // The map holds Futures, so `remove` hands this very future back. We
    // want the eviction, not the value — a later rebuild retries the lookup.
    unawaited(_showPosterRequests.remove(showName));
    return null;
  }
}

/// Provider to lookup movie poster from TMDB based on filename
final moviePosterProvider = FutureProvider.family<String?, String>((
  ref,
  movieName,
) {
  ref.keepAlive();
  return _moviePosterRequests[movieName] ??= _lookupMoviePoster(ref, movieName);
});

Future<String?> _lookupMoviePoster(Ref ref, String movieName) async {
  final tmdb = ref.read(tmdbApiServiceProvider);
  try {
    final movies = await tmdb.searchMovies(movieName);
    return movies.isNotEmpty ? movies.first.posterUrl : null;
  } catch (e) {
    AppLog.w('[LocalMedia] movie poster lookup failed for "$movieName": $e');
    unawaited(_moviePosterRequests.remove(movieName));
    return null;
  }
}

/// Provider for LocalMediaScanner instance
final localMediaScannerProvider = Provider<LocalMediaScanner>((ref) {
  final downloadPath = ref.watch(downloadPathProvider);
  final scanner = LocalMediaScanner(downloadPath);
  ref.onDispose(() => scanner.dispose());
  return scanner;
});

/// Snapshot of all local media files.
///
/// Derived from [localMediaStreamProvider] so it reflects the live watcher
/// state — every `DirectoryWatcher` event re-emits through the stream,
/// which re-runs this provider, which then propagates to all derived
/// providers (recentDownloadsProvider, localMoviesProvider,
/// localMediaByShowAndSeasonProvider, etc.).
///
/// Previously this was an independent one-shot `FutureProvider` doing its
/// own scan. Result: the stream-driven UI saw new files (the "All" count
/// updated) but the derived sub-section lists stayed frozen at the
/// initial scan. Bridging it to the stream gives everything one source
/// of truth.
final localMediaFilesProvider = FutureProvider<List<LocalMediaFile>>((
  ref,
) async {
  // Watch-progress is joined HERE, not inside [localMediaStreamProvider].
  // Watching it there re-ran the stream body on every progress write — and
  // PlayerService saves progress every 10 s during playback — which cancelled
  // the running `watchDirectory()` generator and started a new one, each of
  // which opens with a full `directory.list(recursive: true)` over the whole
  // library (and rebuilds the DirectoryWatcher). Joining downstream means a
  // progress write costs one map over an in-memory list instead.
  final progressMap = ref.watch(watchProgressProvider);
  final streamAsync = ref.watch(localMediaStreamProvider);
  if (streamAsync.hasError) throw streamAsync.error!;
  final files = streamAsync.hasValue
      ? streamAsync.value!
      // Loading — wait for the stream's first emission (initial scan).
      : await ref.watch(localMediaStreamProvider.future);
  return _joinProgress(files, progressMap);
});

/// Attach each file's persisted [WatchProgress], when it has one.
List<LocalMediaFile> _joinProgress(
  List<LocalMediaFile> files,
  Map<String, WatchProgress> progressMap,
) {
  if (progressMap.isEmpty) return files;
  final joined = <LocalMediaFile>[];
  for (final file in files) {
    final progress = progressMap[WatchProgress.generateHash(file.path)];
    joined.add(progress == null ? file : file.copyWith(progress: progress));
  }
  return joined;
}

/// Provider for watching local media files (stream)
///
/// Deliberately depends on nothing but the scanner. Anything else watched here
/// re-runs the body, and re-running the body means re-scanning the entire
/// library from disk — see the note in [localMediaFilesProvider].
///
/// No existence filter either: every emission from watchDirectory() is a
/// fresh `directory.list(recursive: true)`, so these files were enumerated
/// from the filesystem microseconds ago. Re-stat'ing each one was an O(n)
/// syscall pass over the whole library on every watcher event, guarding a
/// race window that the next watcher event corrects anyway.
final localMediaStreamProvider = StreamProvider<List<LocalMediaFile>>((ref) {
  final scanner = ref.watch(localMediaScannerProvider);
  return scanner.watchDirectory();
});

/// Provider for refreshing local media files
final refreshLocalMediaProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    // Invalidate all media providers to force a fresh scan with current path
    ref.invalidate(localMediaStreamProvider);
    ref.invalidate(localMediaScannerProvider);
    ref.invalidate(localMediaFilesProvider);
  };
});

/// Provider for local media grouped by show (case-insensitive)
/// Only includes TV show episodes (files with season OR episode numbers)
final localMediaByShowProvider = Provider<Map<String, List<LocalMediaFile>>>((
  ref,
) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];

  // Filter to only include TV show episodes (files with season OR episode numbers)
  final showFiles = files
      .where((f) => f.seasonNumber != null || f.episodeNumber != null)
      .toList();

  final groupedLower = <String, List<LocalMediaFile>>{};
  final showNameMap =
      <String, String>{}; // lowercase -> original (first seen) name

  for (final file in showFiles) {
    final showName = file.showName ?? 'Unknown Show';
    final showNameLower = showName.toLowerCase();

    // Keep the first encountered name (usually more properly formatted)
    if (!showNameMap.containsKey(showNameLower)) {
      showNameMap[showNameLower] = showName;
    }

    groupedLower.putIfAbsent(showNameLower, () => []);
    groupedLower[showNameLower]!.add(file);
  }

  // Sort shows alphabetically and episodes within each show
  final sortedKeysLower = groupedLower.keys.toList()..sort();
  final sortedGrouped = <String, List<LocalMediaFile>>{};

  for (final keyLower in sortedKeysLower) {
    final displayName = showNameMap[keyLower]!;
    final showFiles = groupedLower[keyLower]!;
    showFiles.sort((a, b) {
      final seasonCompare = (a.seasonNumber ?? 0).compareTo(
        b.seasonNumber ?? 0,
      );
      if (seasonCompare != 0) return seasonCompare;
      return (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0);
    });
    sortedGrouped[displayName] = showFiles;
  }

  return sortedGrouped;
});

/// Model for grouped show with seasons
class ShowWithSeasons {
  final String showName;
  final Map<int, List<LocalMediaFile>> seasons;
  final int totalEpisodes;

  ShowWithSeasons({
    required this.showName,
    required this.seasons,
    required this.totalEpisodes,
  });
}

/// Provider for local media grouped by show AND season
final localMediaByShowAndSeasonProvider = Provider<List<ShowWithSeasons>>((
  ref,
) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];

  // Filter to only include TV show episodes (files with season OR episode numbers)
  // Movies don't have these, so they're excluded
  final showFiles = files
      .where((f) => f.seasonNumber != null || f.episodeNumber != null)
      .toList();

  // First group by show (case-insensitive key, preserve original name)
  final byShowLower = <String, Map<int, List<LocalMediaFile>>>{};
  final showNameMap = <String, String>{}; // lowercase -> original name

  for (final file in showFiles) {
    final showName = file.showName ?? 'Unknown Show';
    final showNameLower = showName.toLowerCase();
    final season = file.seasonNumber ?? 0;

    // Keep the first encountered name (usually more properly formatted)
    if (!showNameMap.containsKey(showNameLower)) {
      showNameMap[showNameLower] = showName;
    }

    byShowLower.putIfAbsent(showNameLower, () => {});
    byShowLower[showNameLower]!.putIfAbsent(season, () => []);
    byShowLower[showNameLower]![season]!.add(file);
  }

  // Convert to list and sort
  final result = <ShowWithSeasons>[];
  final sortedShowNamesLower = byShowLower.keys.toList()..sort();

  for (final showNameLower in sortedShowNamesLower) {
    final displayName = showNameMap[showNameLower]!;
    final seasonsMap = byShowLower[showNameLower]!;

    // Sort seasons and episodes within each season
    final sortedSeasons = <int, List<LocalMediaFile>>{};
    final sortedSeasonNumbers = seasonsMap.keys.toList()..sort();

    int totalEps = 0;
    for (final seasonNum in sortedSeasonNumbers) {
      final episodes = seasonsMap[seasonNum]!;
      episodes.sort(
        (a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0),
      );
      sortedSeasons[seasonNum] = episodes;
      totalEps += episodes.length;
    }

    result.add(
      ShowWithSeasons(
        showName: displayName,
        seasons: sortedSeasons,
        totalEpisodes: totalEps,
      ),
    );
  }

  return result;
});

/// Provider for recently downloaded files
final recentDownloadsProvider = Provider<List<LocalMediaFile>>((ref) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];

  final cutoff = DateTime.now().subtract(const Duration(days: 7));
  return files.where((f) => f.modifiedDate.isAfter(cutoff)).take(10).toList();
});

/// Provider for local movies (files without season/episode info)
final localMoviesProvider = Provider<List<LocalMediaFile>>((ref) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];

  // Movies are files that don't have season/episode numbers
  final movies = files
      .where((f) => f.seasonNumber == null && f.episodeNumber == null)
      .toList();

  // Sort by modified date (newest first)
  movies.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));

  return movies;
});

/// Provider to check if specific episode is available locally
final episodeLocalFileProvider =
    Provider.family<
      LocalMediaFile?,
      ({String showName, int season, int episode})
    >((ref, params) {
      final filesAsync = ref.watch(localMediaFilesProvider);
      final files = filesAsync.value ?? [];

      final scanner = ref.watch(localMediaScannerProvider);
      return scanner.findEpisodeFile(
        files,
        showName: params.showName,
        season: params.season,
        episode: params.episode,
      );
    });

/// Provider to check if a specific movie is available locally (by title match)
final movieLocalFileProvider = Provider.family<LocalMediaFile?, String>((
  ref,
  movieTitle,
) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];

  final normalizedTitle = movieTitle.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );

  // Only check movies (files without season/episode numbers)
  for (final file in files) {
    if (file.seasonNumber != null || file.episodeNumber != null) continue;
    final fileName = (file.showName ?? file.fileName).toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    if (fileName.contains(normalizedTitle) ||
        normalizedTitle.contains(fileName)) {
      return file;
    }
  }
  return null;
});

/// Provider for counting total local files
final localFilesCountProvider = Provider<int>((ref) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  return filesAsync.value?.length ?? 0;
});

/// Provider for counting shows with local files
final localShowsCountProvider = Provider<int>((ref) {
  final grouped = ref.watch(localMediaByShowProvider);
  return grouped.length;
});

/// Provider to find the next episode **already on disk** after a given file.
/// Returns the next episode ONLY if it's the immediate next episode (e.g., E04 after E03)
/// Does NOT skip to later episodes (e.g., won't return E05 if E04 is missing)
///
/// Named for the local library deliberately: [nextTmdbEpisodeProvider] in
/// `auto_download_provider.dart` answers the same question against TMDB and
/// returns a different type. The two were both called `nextEpisodeProvider`
/// and only stayed apart because `video_player_screen.dart` imported one of
/// them with a `hide` clause — the next file to import both would have
/// silently bound the wrong one.
final nextLocalEpisodeProvider = Provider.family<LocalMediaFile?, LocalMediaFile>((
  ref,
  currentFile,
) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];

  if (currentFile.showName == null ||
      currentFile.seasonNumber == null ||
      currentFile.episodeNumber == null) {
    return null;
  }

  final showNameLower = currentFile.showName!.toLowerCase();
  final currentSeason = currentFile.seasonNumber!;
  final currentEpisode = currentFile.episodeNumber!;

  // First, look for the immediate next episode in the same season (e.g., E04 after E03)
  final nextInSeason = files
      .where(
        (f) =>
            f.showName?.toLowerCase() == showNameLower &&
            f.seasonNumber == currentSeason &&
            f.episodeNumber == currentEpisode + 1,
      )
      .firstOrNull;

  if (nextInSeason != null) {
    return nextInSeason;
  }

  // If current episode might be the last of the season, check for S+1 E01
  // But only if we're at the end of the season (we'll check TMDB for this in player)
  // For now, just check if episode 1 of next season exists
  final firstOfNextSeason = files
      .where(
        (f) =>
            f.showName?.toLowerCase() == showNameLower &&
            f.seasonNumber == currentSeason + 1 &&
            f.episodeNumber == 1,
      )
      .firstOrNull;

  // Only return first of next season if we don't have any more episodes in current season
  // This is a simple heuristic - the video player will do the proper TMDB check
  if (firstOfNextSeason != null) {
    // Check if there are any episodes after current in same season
    final hasMoreInSeason = files.any(
      (f) =>
          f.showName?.toLowerCase() == showNameLower &&
          f.seasonNumber == currentSeason &&
          f.episodeNumber != null &&
          f.episodeNumber! > currentEpisode,
    );

    // Only skip to next season if no more episodes exist in current season
    // (This could mean current episode is last, or we're missing some)
    // The video player will verify with TMDB if this is correct
    if (!hasMoreInSeason) {
      return firstOfNextSeason;
    }
  }

  // No immediate next episode found
  return null;
});
