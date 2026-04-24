import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/local_media_file.dart';
import '../models/watch_progress.dart';
import '../services/local_media_scanner.dart';
import '../services/tmdb_api_service.dart';
import 'settings_provider.dart';
import 'watch_progress_provider.dart';

/// Provider for download save path from settings
final downloadPathProvider = Provider<String>((ref) {
  return ref.watch(settingsProvider).defaultSavePath;
});

/// Provider for TMDB API service — key is sourced from user settings.
final tmdbServiceProvider = Provider<TmdbApiService>((ref) {
  final apiKey = ref.watch(settingsProvider.select((s) => s.tmdbApiKey));
  return TmdbApiService(apiKey: apiKey);
});

/// Cache for show poster lookups
final _showPosterCache = <String, String?>{};

/// Cache for movie poster lookups
final _moviePosterCache = <String, String?>{};

/// Provider to lookup show poster from TMDB
final showPosterProvider = FutureProvider.family<String?, String>((ref, showName) async {
  // Check cache first
  if (_showPosterCache.containsKey(showName)) {
    return _showPosterCache[showName];
  }
  
  final tmdb = ref.read(tmdbServiceProvider);
  try {
    final shows = await tmdb.searchShows(showName);
    if (shows.isNotEmpty) {
      final posterPath = shows.first.posterPath;
      final posterUrl = posterPath != null 
          ? TmdbApiService.getPosterUrl(posterPath, size: 'w185')
          : null;
      _showPosterCache[showName] = posterUrl;
      return posterUrl;
    }
  } catch (e) {
    // Silently fail - just return null for poster
  }
  _showPosterCache[showName] = null;
  return null;
});

/// Provider to lookup movie poster from TMDB based on filename
final moviePosterProvider = FutureProvider.family<String?, String>((ref, movieName) async {
  // Check cache first
  if (_moviePosterCache.containsKey(movieName)) {
    return _moviePosterCache[movieName];
  }
  
  final tmdb = ref.read(tmdbServiceProvider);
  try {
    final movies = await tmdb.searchMovies(movieName);
    if (movies.isNotEmpty) {
      final posterPath = movies.first.posterUrl;
      _moviePosterCache[movieName] = posterPath;
      return posterPath;
    }
  } catch (e) {
    // Silently fail - just return null for poster
  }
  _moviePosterCache[movieName] = null;
  return null;
});

/// Provider for LocalMediaScanner instance
final localMediaScannerProvider = Provider<LocalMediaScanner>((ref) {
  final downloadPath = ref.watch(downloadPathProvider);
  final scanner = LocalMediaScanner(downloadPath);
  ref.onDispose(() => scanner.dispose());
  return scanner;
});

/// Provider for all local media files (scanned once)
final localMediaFilesProvider = FutureProvider<List<LocalMediaFile>>((ref) async {
  final scanner = ref.watch(localMediaScannerProvider);
  final files = await scanner.scanDirectory();

  // Filter out files that no longer exist on disk
  final existingFiles = files.where((f) => File(f.path).existsSync()).toList();

  // Attach watch progress to files
  final progressMap = ref.watch(watchProgressProvider);

  return existingFiles.map((file) {
    final hash = WatchProgress.generateHash(file.path);
    final progress = progressMap[hash];
    return progress != null ? file.copyWith(progress: progress) : file;
  }).toList();
});

/// Provider for watching local media files (stream)
final localMediaStreamProvider = StreamProvider<List<LocalMediaFile>>((ref) {
  final scanner = ref.watch(localMediaScannerProvider);
  final progressMap = ref.watch(watchProgressProvider);
  
  return scanner.watchDirectory().map((files) {
    return files.where((f) => File(f.path).existsSync()).map((file) {
      final hash = WatchProgress.generateHash(file.path);
      final progress = progressMap[hash];
      return progress != null ? file.copyWith(progress: progress) : file;
    }).toList();
  });
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
final localMediaByShowProvider = Provider<Map<String, List<LocalMediaFile>>>((ref) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];
  
  // Filter to only include TV show episodes (files with season OR episode numbers)
  final showFiles = files.where((f) => 
    f.seasonNumber != null || f.episodeNumber != null
  ).toList();
  
  final groupedLower = <String, List<LocalMediaFile>>{};
  final showNameMap = <String, String>{}; // lowercase -> original (first seen) name
  
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
      final seasonCompare = (a.seasonNumber ?? 0).compareTo(b.seasonNumber ?? 0);
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
final localMediaByShowAndSeasonProvider = Provider<List<ShowWithSeasons>>((ref) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];
  
  // Filter to only include TV show episodes (files with season OR episode numbers)
  // Movies don't have these, so they're excluded
  final showFiles = files.where((f) => 
    f.seasonNumber != null || f.episodeNumber != null
  ).toList();
  
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
      episodes.sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
      sortedSeasons[seasonNum] = episodes;
      totalEps += episodes.length;
    }
    
    result.add(ShowWithSeasons(
      showName: displayName,
      seasons: sortedSeasons,
      totalEpisodes: totalEps,
    ));
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
  final movies = files.where((f) => 
    f.seasonNumber == null && f.episodeNumber == null
  ).toList();
  
  // Sort by modified date (newest first)
  movies.sort((a, b) => b.modifiedDate.compareTo(a.modifiedDate));
  
  return movies;
});

/// Provider to check if specific episode is available locally
final episodeLocalFileProvider =
    Provider.family<LocalMediaFile?, ({String showName, int season, int episode})>((ref, params) {
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
final movieLocalFileProvider =
    Provider.family<LocalMediaFile?, String>((ref, movieTitle) {
  final filesAsync = ref.watch(localMediaFilesProvider);
  final files = filesAsync.value ?? [];

  final normalizedTitle = movieTitle.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  // Only check movies (files without season/episode numbers)
  for (final file in files) {
    if (file.seasonNumber != null || file.episodeNumber != null) continue;
    final fileName = (file.showName ?? file.fileName).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (fileName.contains(normalizedTitle) || normalizedTitle.contains(fileName)) {
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

/// Provider to find the next episode after a given file
/// Returns the next episode ONLY if it's the immediate next episode (e.g., E04 after E03)
/// Does NOT skip to later episodes (e.g., won't return E05 if E04 is missing)
final nextEpisodeProvider = Provider.family<LocalMediaFile?, LocalMediaFile>((ref, currentFile) {
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
  final nextInSeason = files.where((f) => 
    f.showName?.toLowerCase() == showNameLower &&
    f.seasonNumber == currentSeason &&
    f.episodeNumber == currentEpisode + 1
  ).firstOrNull;
  
  if (nextInSeason != null) {
    return nextInSeason;
  }
  
  // If current episode might be the last of the season, check for S+1 E01
  // But only if we're at the end of the season (we'll check TMDB for this in player)
  // For now, just check if episode 1 of next season exists
  final firstOfNextSeason = files.where((f) => 
    f.showName?.toLowerCase() == showNameLower &&
    f.seasonNumber == currentSeason + 1 &&
    f.episodeNumber == 1
  ).firstOrNull;
  
  // Only return first of next season if we don't have any more episodes in current season
  // This is a simple heuristic - the video player will do the proper TMDB check
  if (firstOfNextSeason != null) {
    // Check if there are any episodes after current in same season
    final hasMoreInSeason = files.any((f) => 
      f.showName?.toLowerCase() == showNameLower &&
      f.seasonNumber == currentSeason &&
      f.episodeNumber != null &&
      f.episodeNumber! > currentEpisode
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
