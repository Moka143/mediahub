import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../models/show_with_seasons.dart';
import '../models/watch_progress.dart';
import '../services/app_logger.dart';
import '../services/local_media_scanner.dart';
import '../services/tmdb_api_service.dart';
import '../utils/media_names.dart';
import 'settings_provider.dart';
import 'shows_provider.dart';
import 'watch_progress_provider.dart';

/// Provider for download save path from settings
final downloadPathProvider = Provider<String>((ref) {
  return ref.watch(settingsProvider).defaultSavePath;
});

/// Provider to lookup show poster from TMDB.
///
/// Kept alive from the first request, not just while a card watches it: the
/// library list churns constantly — the torrent poll rebuilds it every 2 s
/// while a download runs — and a lookup cancelled every time its card was
/// rebuilt never finished at all. A *failure* is let go instead: it is
/// rethrown (Riverpod retries it while watched) and released once nothing
/// watches it, so the next card to ask tries again. It used to resolve to
/// null and stay cached for the session, leaving the card on a flat
/// gradient with no way back.
final showPosterProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  showName,
) async {
  final tmdb = ref.watch(tmdbApiServiceProvider);
  final keepAlive = ref.keepAlive();
  try {
    final shows = await tmdb.searchShows(showName);
    if (shows.isEmpty) return null;
    // The same show by name when the results have it — a poster is only
    // cosmetic, but the first hit for "You" is not necessarily "You".
    final show = shows.firstWhere(
      (s) => titlesMatch(s.name, showName),
      orElse: () => shows.first,
    );
    final posterPath = show.posterPath;
    return posterPath != null
        ? TmdbApiService.getPosterUrl(posterPath, size: 'w185')
        : null;
  } catch (e) {
    AppLog.w('[LocalMedia] show poster lookup failed for "$showName": $e');
    keepAlive.close();
    rethrow;
  }
});

/// Provider to lookup movie poster from TMDB based on filename. Same
/// caching rules as [showPosterProvider].
final moviePosterProvider = FutureProvider.autoDispose.family<String?, String>((
  ref,
  movieName,
) async {
  final tmdb = ref.watch(tmdbApiServiceProvider);
  final keepAlive = ref.keepAlive();
  try {
    final movies = await tmdb.searchMovies(movieName);
    if (movies.isEmpty) return null;
    final movie = movies.firstWhere(
      (m) => titlesMatch(m.title, movieName),
      orElse: () => movies.first,
    );
    return movie.posterUrl;
  } catch (e) {
    AppLog.w('[LocalMedia] movie poster lookup failed for "$movieName": $e');
    keepAlive.close();
    rethrow;
  }
});

/// Provider for LocalMediaScanner instance
final localMediaScannerProvider = Provider<LocalMediaScanner>((ref) {
  final downloadPath = ref.watch(downloadPathProvider);
  return LocalMediaScanner(downloadPath);
});

/// Rescan the library — **the** way to do it.
///
/// Invalidating the scanner is enough: the file stream and the file list are
/// built on it, and everything derived rebuilds from those. Invalidating
/// only the file list — what several call sites did — re-joined the stream's
/// cached value without scanning anything.
void refreshLocalMedia(WidgetRef ref) =>
    ref.invalidate(localMediaScannerProvider);

/// [refreshLocalMedia] for code that holds a provider [Ref] — a notifier —
/// rather than a [WidgetRef].
void refreshLocalMediaFromRef(Ref ref) =>
    ref.invalidate(localMediaScannerProvider);

/// Snapshot of all local media files.
///
/// Derived from [localMediaStreamProvider] so it reflects the live watcher
/// state — every `DirectoryWatcher` event re-emits through the stream,
/// which re-runs this provider, which then propagates to all derived
/// providers (recentDownloadsProvider, localMoviesProvider,
/// localMediaByShowAndSeasonProvider, etc.).
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

/// Attach each file's persisted [WatchProgress], when it has one — and with
/// it the TMDB show id and poster the row learned, which the scanner cannot
/// know. Those two fields were declared on every library file and set on
/// none, so everything that read them got null.
List<LocalMediaFile> _joinProgress(
  List<LocalMediaFile> files,
  Map<String, WatchProgress> progressMap,
) {
  if (progressMap.isEmpty) return files;
  final joined = <LocalMediaFile>[];
  for (final file in files) {
    final progress = progressMap[WatchProgress.generateHash(file.path)];
    joined.add(
      progress == null
          ? file
          : file.copyWith(
              progress: progress,
              showId: file.showId ?? progress.showId,
              posterPath: file.posterPath ?? progress.posterPath,
            ),
    );
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
/// from the filesystem moments ago.
final localMediaStreamProvider = StreamProvider<List<LocalMediaFile>>((ref) {
  final scanner = ref.watch(localMediaScannerProvider);
  return scanner.watchDirectory();
});

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

/// The library movie file for [title] (released in [year], when known), or
/// null.
///
/// Same title, never containment: matching either name *inside* the other
/// made the "Up" page play `Upgrade.2018.mkv` and `Pickup…`, and a non-Latin
/// title — which the old normaliser erased to an empty string — matched the
/// first movie in the library. Each way the file name can be read is tried
/// ([movieQueriesFromFileName]), so `Wonder.Woman.1984.2020.mkv` is found for
/// "Wonder Woman 1984" (2020) and not for "Wonder Woman" (2017).
///
/// Without a [year], two files of the same title from different years are
/// not guessed between.
@visibleForTesting
LocalMediaFile? findMovieFile(
  List<LocalMediaFile> files, {
  required String title,
  int? year,
}) {
  if (titleMatchKey(title).isEmpty) return null;
  final matches = <({LocalMediaFile file, int? year})>[];
  for (final file in files) {
    if (file.seasonNumber != null || file.episodeNumber != null) continue;
    for (final reading in movieQueriesFromFileName(file.fileName)) {
      if (!titlesMatch(reading.title, title)) continue;
      if (year != null && reading.year != null && reading.year != year) {
        continue;
      }
      matches.add((file: file, year: reading.year));
      break;
    }
  }
  if (matches.isEmpty) return null;
  if (year == null && matches.map((m) => m.year).toSet().length > 1) {
    return null;
  }
  return matches.first.file;
}

/// Provider to check if a specific movie is available locally, by title and
/// release year. See [findMovieFile].
final localMovieFileProvider =
    Provider.family<LocalMediaFile?, ({String title, int? year})>((ref, movie) {
      final files = ref.watch(localMediaFilesProvider).value ?? const [];
      return findMovieFile(files, title: movie.title, year: movie.year);
    });
