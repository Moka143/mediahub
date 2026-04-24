import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/watch_progress.dart';
import 'local_media_provider.dart';
import 'settings_provider.dart';

/// Key for storing watch progress in SharedPreferences
const _watchProgressKey = 'watch_progress';
const _manualWatchedKey = 'manual_watched_episodes';

/// Provider for all watch progress entries
final watchProgressProvider =
    NotifierProvider<WatchProgressNotifier, Map<String, WatchProgress>>(
  WatchProgressNotifier.new,
);

/// Provider for manual watched state (season/show level)
final manualWatchedProvider =
    NotifierProvider<ManualWatchedNotifier, ManualWatchedState>(
  ManualWatchedNotifier.new,
);

/// State class for manual watched tracking
class ManualWatchedState {
  /// Map of showId -> Set of "S01E05" episode codes marked as watched
  final Map<int, Set<String>> watchedEpisodes;
  
  /// Map of showId -> Set of season numbers marked as watched
  final Map<int, Set<int>> watchedSeasons;
  
  /// Set of showIds marked as fully watched
  final Set<int> watchedShows;

  const ManualWatchedState({
    this.watchedEpisodes = const {},
    this.watchedSeasons = const {},
    this.watchedShows = const {},
  });

  ManualWatchedState copyWith({
    Map<int, Set<String>>? watchedEpisodes,
    Map<int, Set<int>>? watchedSeasons,
    Set<int>? watchedShows,
  }) {
    return ManualWatchedState(
      watchedEpisodes: watchedEpisodes ?? this.watchedEpisodes,
      watchedSeasons: watchedSeasons ?? this.watchedSeasons,
      watchedShows: watchedShows ?? this.watchedShows,
    );
  }

  bool isEpisodeWatched(int showId, int season, int episode) {
    final episodeCode = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    return watchedEpisodes[showId]?.contains(episodeCode) ?? false;
  }

  bool isSeasonWatched(int showId, int season) {
    return watchedSeasons[showId]?.contains(season) ?? false;
  }

  bool isShowWatched(int showId) {
    return watchedShows.contains(showId);
  }

  Map<String, dynamic> toJson() {
    return {
      'watched_episodes': watchedEpisodes.map(
        (k, v) => MapEntry(k.toString(), v.toList()),
      ),
      'watched_seasons': watchedSeasons.map(
        (k, v) => MapEntry(k.toString(), v.toList()),
      ),
      'watched_shows': watchedShows.toList(),
    };
  }

  factory ManualWatchedState.fromJson(Map<String, dynamic> json) {
    return ManualWatchedState(
      watchedEpisodes: (json['watched_episodes'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(
              int.parse(k),
              (v as List).map((e) => e as String).toSet(),
            ),
          ) ??
          {},
      watchedSeasons: (json['watched_seasons'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(
              int.parse(k),
              (v as List).map((e) => e as int).toSet(),
            ),
          ) ??
          {},
      watchedShows: (json['watched_shows'] as List?)
              ?.map((e) => e as int)
              .toSet() ??
          {},
    );
  }
}

/// Notifier for manual watched state
class ManualWatchedNotifier extends Notifier<ManualWatchedState> {
  @override
  ManualWatchedState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return _loadState(prefs);
  }

  ManualWatchedState _loadState(SharedPreferences prefs) {
    try {
      final jsonString = prefs.getString(_manualWatchedKey);
      if (jsonString == null) return const ManualWatchedState();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return ManualWatchedState.fromJson(json);
    } catch (e) {
      print('Error loading manual watched state: $e');
      return const ManualWatchedState();
    }
  }

  Future<void> _saveState() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setString(_manualWatchedKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('Error saving manual watched state: $e');
    }
  }

  /// Mark a specific episode as watched
  Future<void> markEpisodeWatched(int showId, int season, int episode) async {
    final episodeCode = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    final newEpisodes = Map<int, Set<String>>.from(state.watchedEpisodes);
    newEpisodes.putIfAbsent(showId, () => {});
    newEpisodes[showId] = Set<String>.from(newEpisodes[showId]!)..add(episodeCode);
    
    state = state.copyWith(watchedEpisodes: newEpisodes);
    await _saveState();
  }

  /// Mark a specific episode as unwatched
  Future<void> markEpisodeUnwatched(int showId, int season, int episode) async {
    final episodeCode = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    final newEpisodes = Map<int, Set<String>>.from(state.watchedEpisodes);
    if (newEpisodes.containsKey(showId)) {
      newEpisodes[showId] = Set<String>.from(newEpisodes[showId]!)..remove(episodeCode);
      if (newEpisodes[showId]!.isEmpty) {
        newEpisodes.remove(showId);
      }
    }
    
    // Also remove from season/show watched
    final newSeasons = Map<int, Set<int>>.from(state.watchedSeasons);
    if (newSeasons.containsKey(showId)) {
      newSeasons[showId] = Set<int>.from(newSeasons[showId]!)..remove(season);
    }
    final newShows = Set<int>.from(state.watchedShows)..remove(showId);
    
    state = state.copyWith(
      watchedEpisodes: newEpisodes,
      watchedSeasons: newSeasons,
      watchedShows: newShows,
    );
    await _saveState();
  }

  /// Mark an entire season as watched
  Future<void> markSeasonWatched(int showId, int season) async {
    final newSeasons = Map<int, Set<int>>.from(state.watchedSeasons);
    newSeasons.putIfAbsent(showId, () => {});
    newSeasons[showId] = Set<int>.from(newSeasons[showId]!)..add(season);
    
    state = state.copyWith(watchedSeasons: newSeasons);
    await _saveState();
  }

  /// Mark an entire season as unwatched
  Future<void> markSeasonUnwatched(int showId, int season) async {
    final newSeasons = Map<int, Set<int>>.from(state.watchedSeasons);
    if (newSeasons.containsKey(showId)) {
      newSeasons[showId] = Set<int>.from(newSeasons[showId]!)..remove(season);
      if (newSeasons[showId]!.isEmpty) {
        newSeasons.remove(showId);
      }
    }
    
    // Also remove from show watched
    final newShows = Set<int>.from(state.watchedShows)..remove(showId);
    
    state = state.copyWith(
      watchedSeasons: newSeasons,
      watchedShows: newShows,
    );
    await _saveState();
  }

  /// Mark an entire show as watched
  Future<void> markShowWatched(int showId) async {
    final newShows = Set<int>.from(state.watchedShows)..add(showId);
    state = state.copyWith(watchedShows: newShows);
    await _saveState();
  }

  /// Mark an entire show as unwatched
  Future<void> markShowUnwatched(int showId) async {
    final newShows = Set<int>.from(state.watchedShows)..remove(showId);
    final newSeasons = Map<int, Set<int>>.from(state.watchedSeasons)..remove(showId);
    final newEpisodes = Map<int, Set<String>>.from(state.watchedEpisodes)..remove(showId);
    
    state = state.copyWith(
      watchedShows: newShows,
      watchedSeasons: newSeasons,
      watchedEpisodes: newEpisodes,
    );
    await _saveState();
  }

  /// Toggle episode watched state
  Future<void> toggleEpisodeWatched(int showId, int season, int episode) async {
    if (state.isEpisodeWatched(showId, season, episode)) {
      await markEpisodeUnwatched(showId, season, episode);
    } else {
      await markEpisodeWatched(showId, season, episode);
    }
  }

  /// Check if episode is watched (from any source)
  bool isEpisodeWatched(int showId, int season, int episode) {
    // Check show level first
    if (state.isShowWatched(showId)) return true;
    // Check season level
    if (state.isSeasonWatched(showId, season)) return true;
    // Check episode level
    return state.isEpisodeWatched(showId, season, episode);
  }
}

/// Provider to check if a specific episode is watched
final isEpisodeWatchedProvider = Provider.family<bool, ({int showId, int season, int episode})>((ref, params) {
  final manualWatched = ref.watch(manualWatchedProvider);
  return manualWatched.isEpisodeWatched(params.showId, params.season, params.episode) ||
         manualWatched.isSeasonWatched(params.showId, params.season) ||
         manualWatched.isShowWatched(params.showId);
});

/// Provider for "Continue Watching" items (in progress, not completed)
/// Filters out items where the file no longer exists
final continueWatchingProvider = Provider<List<WatchProgress>>((ref) {
  final progress = ref.watch(watchProgressProvider);
  // Watch media files so we recompute when the file list changes (e.g. torrent deleted)
  ref.watch(localMediaFilesProvider);

  // Filter: in progress, not completed, and file still exists
  final validProgress = progress.values.where((p) {
    if (p.isCompleted || p.progress <= 0.05) return false;
    return File(p.filePath).existsSync();
  }).toList();

  // Sort by last watched (most recent first)
  validProgress.sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
  return validProgress;
});

/// Provider for completed (watched) items — only if file still exists
final watchedItemsProvider = Provider<List<WatchProgress>>((ref) {
  final progress = ref.watch(watchProgressProvider);
  // Watch media files so we recompute when the file list changes (e.g. torrent deleted)
  ref.watch(localMediaFilesProvider);
  return progress.values
      .where((p) => p.isCompleted && File(p.filePath).existsSync())
      .toList()
    ..sort((a, b) => b.lastWatched.compareTo(a.lastWatched));
});

/// Provider for watch progress of specific file
final fileWatchProgressProvider =
    Provider.family<WatchProgress?, String>((ref, filePath) {
  final progress = ref.watch(watchProgressProvider);
  final hash = WatchProgress.generateHash(filePath);
  return progress[hash];
});

/// Notifier for managing watch progress
class WatchProgressNotifier extends Notifier<Map<String, WatchProgress>> {
  @override
  Map<String, WatchProgress> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return _loadProgress(prefs);
  }

  /// Load progress from SharedPreferences
  Map<String, WatchProgress> _loadProgress(SharedPreferences prefs) {
    try {
      final jsonString = prefs.getString(_watchProgressKey);
      if (jsonString == null) return {};

      final jsonList = jsonDecode(jsonString) as List<dynamic>;
      final map = <String, WatchProgress>{};
      
      for (final item in jsonList) {
        final progress = WatchProgress.fromJson(item as Map<String, dynamic>);
        map[progress.fileHash] = progress;
      }
      
      return map;
    } catch (e) {
      print('Error loading watch progress: $e');
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
      print('Error saving watch progress: $e');
    }
  }

  /// Update or create progress for a file
  Future<void> updateProgress(WatchProgress progress) async {
    // Check if should mark as completed
    final updatedProgress = progress.shouldMarkCompleted && !progress.isCompleted
        ? progress.copyWith(isCompleted: true)
        : progress;

    state = {...state, updatedProgress.fileHash: updatedProgress};
    await _saveProgress();
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
      episodeCode: seasonNumber != null && episodeNumber != null
          ? 'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}'
          : null,
      episodeTitle: episodeTitle,
      posterPath: posterPath,
      position: position,
      duration: duration,
      lastWatched: DateTime.now(),
    );

    await updateProgress(progress);
  }

  /// Mark a file as completed (watched)
  Future<void> markCompleted(String filePath) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];

    if (existing != null) {
      final updated = existing.copyWith(
        isCompleted: true,
        lastWatched: DateTime.now(),
      );
      state = {...state, hash: updated};
      await _saveProgress();
    }
  }

  /// Mark a file as not completed (unwatched)
  Future<void> markNotCompleted(String filePath) async {
    final hash = WatchProgress.generateHash(filePath);
    final existing = state[hash];

    if (existing != null) {
      final updated = existing.copyWith(
        isCompleted: false,
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

  /// Remove watch progress entries whose files no longer exist on disk
  Future<void> cleanupStaleEntries() async {
    final staleKeys = state.entries
        .where((e) => !File(e.value.filePath).existsSync())
        .map((e) => e.key)
        .toList();

    if (staleKeys.isEmpty) return;

    final newState = Map<String, WatchProgress>.from(state);
    for (final key in staleKeys) {
      newState.remove(key);
    }
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
