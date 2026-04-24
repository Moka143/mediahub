import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/show.dart';
import '../services/tmdb_api_service.dart';
import 'shows_provider.dart';
import 'settings_provider.dart';

/// Key for storing favorites in SharedPreferences
const String _favoritesKey = 'favorite_shows';
const String _lastCheckedKey = 'favorites_last_checked';
const String _newEpisodesKey = 'new_episodes_count';

/// State class for favorites
class FavoritesState {
  final Set<int> favoriteIds;
  final Map<int, Show> cachedShows;
  final bool isLoading;
  final String? error;

  const FavoritesState({
    this.favoriteIds = const {},
    this.cachedShows = const {},
    this.isLoading = false,
    this.error,
  });

  FavoritesState copyWith({
    Set<int>? favoriteIds,
    Map<int, Show>? cachedShows,
    bool? isLoading,
    String? error,
  }) {
    return FavoritesState(
      favoriteIds: favoriteIds ?? this.favoriteIds,
      cachedShows: cachedShows ?? this.cachedShows,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  bool isFavorite(int showId) => favoriteIds.contains(showId);
}

/// Notifier for managing favorites (using new Riverpod 2.0+ Notifier pattern)
class FavoritesNotifier extends Notifier<FavoritesState> {
  @override
  FavoritesState build() {
    // sharedPreferencesProvider is synchronous — no microtask needed, no flash.
    final prefs = ref.watch(sharedPreferencesProvider);
    return _loadFromPrefs(prefs);
  }

  TmdbApiService get _tmdbService => ref.read(tmdbApiServiceProvider);

  FavoritesState _loadFromPrefs(SharedPreferences prefs) {
    try {
      final favoritesJson = prefs.getString(_favoritesKey);
      if (favoritesJson != null) {
        final List<dynamic> decoded = jsonDecode(favoritesJson);
        final ids = decoded.map((id) => id as int).toSet();
        return FavoritesState(favoriteIds: ids);
      }
    } catch (_) {}
    return const FavoritesState();
  }

  /// Save favorites to SharedPreferences
  Future<void> _saveFavorites() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final json = jsonEncode(state.favoriteIds.toList());
      await prefs.setString(_favoritesKey, json);
    } catch (e) {
      state = state.copyWith(error: 'Failed to save favorites: $e');
    }
  }

  /// Add a show to favorites
  Future<void> addFavorite(int showId, {Show? show}) async {
    final newIds = Set<int>.from(state.favoriteIds)..add(showId);
    
    Map<int, Show>? newCache;
    if (show != null) {
      newCache = Map<int, Show>.from(state.cachedShows)..[showId] = show;
    }

    state = state.copyWith(
      favoriteIds: newIds,
      cachedShows: newCache,
    );
    await _saveFavorites();
  }

  /// Remove a show from favorites
  Future<void> removeFavorite(int showId) async {
    final newIds = Set<int>.from(state.favoriteIds)..remove(showId);
    final newCache = Map<int, Show>.from(state.cachedShows)..remove(showId);

    state = state.copyWith(
      favoriteIds: newIds,
      cachedShows: newCache,
    );
    await _saveFavorites();
  }

  /// Toggle favorite status
  Future<void> toggleFavorite(int showId, {Show? show}) async {
    if (state.favoriteIds.contains(showId)) {
      await removeFavorite(showId);
    } else {
      await addFavorite(showId, show: show);
    }
  }

  /// Check if a show is favorited
  bool isFavorite(int showId) => state.favoriteIds.contains(showId);

  /// Load full show details for favorites
  Future<void> loadFavoriteDetails() async {
    if (state.favoriteIds.isEmpty) return;

    state = state.copyWith(isLoading: true);
    try {
      final newCache = Map<int, Show>.from(state.cachedShows);

      for (final id in state.favoriteIds) {
        if (!newCache.containsKey(id)) {
          try {
            final show = await _tmdbService.getShowDetails(id);
            newCache[id] = show;
          } catch (_) {
            // Skip shows that fail to load
          }
        }
      }

      state = state.copyWith(cachedShows: newCache, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  /// Get cached show or null
  Show? getCachedShow(int showId) => state.cachedShows[showId];

  /// Clear all favorites
  Future<void> clearFavorites() async {
    state = state.copyWith(
      favoriteIds: {},
      cachedShows: {},
    );
    await _saveFavorites();
  }
}

/// Provider for managing favorite shows
final favoritesProvider = NotifierProvider<FavoritesNotifier, FavoritesState>(
  FavoritesNotifier.new,
);

/// Check if a show is favorited
final isFavoriteProvider = Provider.family<bool, int>((ref, showId) {
  final favorites = ref.watch(favoritesProvider);
  return favorites.favoriteIds.contains(showId);
});

/// Provider for favorite show details (loads full show info)
final favoriteShowsProvider = FutureProvider<List<Show>>((ref) async {
  final favorites = ref.watch(favoritesProvider);
  final tmdbService = ref.read(tmdbApiServiceProvider);

  if (favorites.favoriteIds.isEmpty) return [];

  // Fetch details for all favorites
  final List<Show> shows = [];
  for (final id in favorites.favoriteIds) {
    try {
      final show = await tmdbService.getShowDetails(id);
      shows.add(show);
    } catch (_) {
      // Skip shows that fail to load
    }
  }

  return shows;
});

/// Provider for upcoming episodes from favorite shows
final upcomingEpisodesProvider = FutureProvider<List<UpcomingEpisode>>((ref) async {
  final favorites = ref.watch(favoritesProvider);
  final tmdbService = ref.read(tmdbApiServiceProvider);

  if (favorites.favoriteIds.isEmpty) return [];

  final List<UpcomingEpisode> upcoming = [];

  for (final showId in favorites.favoriteIds) {
    try {
      final show = await tmdbService.getShowDetails(showId);
      if (show.nextEpisodeToAir != null && show.inProduction) {
        upcoming.add(UpcomingEpisode(
          show: show,
          airDate: show.nextEpisodeToAir!,
        ));
      }
    } catch (_) {
      // Skip shows that fail to load
    }
  }

  // Sort by air date
  upcoming.sort((a, b) => a.airDate.compareTo(b.airDate));
  return upcoming;
});

/// Represents an upcoming episode from a favorite show
class UpcomingEpisode {
  final Show show;
  final String airDate;

  UpcomingEpisode({
    required this.show,
    required this.airDate,
  });

  DateTime? get airDateTime {
    try {
      return DateTime.parse(airDate);
    } catch (_) {
      return null;
    }
  }

  int get daysUntilAir {
    final date = airDateTime;
    if (date == null) return -1;
    return date.difference(DateTime.now()).inDays;
  }

  String get daysUntilAirFormatted {
    final days = daysUntilAir;
    if (days < 0) return 'Aired';
    if (days == 0) return 'Today';
    if (days == 1) return 'Tomorrow';
    return 'In $days days';
  }
}

// ============================================================================
// New Episode Notification System (Stremio-inspired)
// ============================================================================

/// State for new episode notifications
class NewEpisodeNotificationsState {
  /// Map of showId -> count of new episodes since last check
  final Map<int, int> newEpisodeCounts;
  
  /// Last time we checked for new episodes
  final DateTime? lastChecked;

  const NewEpisodeNotificationsState({
    this.newEpisodeCounts = const {},
    this.lastChecked,
  });

  NewEpisodeNotificationsState copyWith({
    Map<int, int>? newEpisodeCounts,
    DateTime? lastChecked,
  }) {
    return NewEpisodeNotificationsState(
      newEpisodeCounts: newEpisodeCounts ?? this.newEpisodeCounts,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }

  int getNewCount(int showId) => newEpisodeCounts[showId] ?? 0;
  
  int get totalNewEpisodes => newEpisodeCounts.values.fold(0, (a, b) => a + b);
  
  bool hasNewEpisodes(int showId) => (newEpisodeCounts[showId] ?? 0) > 0;
}

/// Notifier for new episode notifications
class NewEpisodeNotificationsNotifier extends Notifier<NewEpisodeNotificationsState> {
  @override
  NewEpisodeNotificationsState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return _loadState(prefs);
  }

  NewEpisodeNotificationsState _loadState(SharedPreferences prefs) {
    try {
      final lastCheckedStr = prefs.getString(_lastCheckedKey);
      final countsJson = prefs.getString(_newEpisodesKey);
      
      DateTime? lastChecked;
      if (lastCheckedStr != null) {
        lastChecked = DateTime.tryParse(lastCheckedStr);
      }
      
      Map<int, int> counts = {};
      if (countsJson != null) {
        final decoded = jsonDecode(countsJson) as Map<String, dynamic>;
        counts = decoded.map((k, v) => MapEntry(int.parse(k), v as int));
      }
      
      return NewEpisodeNotificationsState(
        newEpisodeCounts: counts,
        lastChecked: lastChecked,
      );
    } catch (e) {
      return const NewEpisodeNotificationsState();
    }
  }

  Future<void> _saveState() async {
    final prefs = ref.read(sharedPreferencesProvider);
    
    if (state.lastChecked != null) {
      await prefs.setString(_lastCheckedKey, state.lastChecked!.toIso8601String());
    }
    
    final countsJson = jsonEncode(
      state.newEpisodeCounts.map((k, v) => MapEntry(k.toString(), v)),
    );
    await prefs.setString(_newEpisodesKey, countsJson);
  }

  /// Check for new episodes for all favorite shows
  Future<void> checkForNewEpisodes() async {
    final favorites = ref.read(favoritesProvider);
    final tmdbService = ref.read(tmdbApiServiceProvider);
    
    if (favorites.favoriteIds.isEmpty) return;
    
    final now = DateTime.now();
    final lastChecked = state.lastChecked ?? now.subtract(const Duration(days: 7));
    
    final newCounts = <int, int>{};
    
    for (final showId in favorites.favoriteIds) {
      try {
        final show = await tmdbService.getShowDetails(showId);
        final numSeasons = show.numberOfSeasons ?? 0;
        
        // Count episodes that aired since last check
        int newCount = 0;
        
        // Check only the last season for efficiency
        if (numSeasons > 0) {
          try {
            final episodes = await tmdbService.getSeasonEpisodes(showId, numSeasons);
            
            for (final episode in episodes) {
              if (episode.airDate == null) continue;
              
              final airDate = DateTime.tryParse(episode.airDate!);
              if (airDate == null) continue;
              
              // Episode aired after last check and before now
              if (airDate.isAfter(lastChecked) && airDate.isBefore(now)) {
                newCount++;
              }
            }
          } catch (_) {}
        }
        
        if (newCount > 0) {
          newCounts[showId] = newCount;
        }
      } catch (_) {}
    }
    
    state = state.copyWith(
      newEpisodeCounts: newCounts,
      lastChecked: now,
    );
    await _saveState();
  }

  /// Clear new episode count for a specific show
  Future<void> clearNewEpisodes(int showId) async {
    final newCounts = Map<int, int>.from(state.newEpisodeCounts);
    newCounts.remove(showId);
    
    state = state.copyWith(newEpisodeCounts: newCounts);
    await _saveState();
  }

  /// Clear all new episode notifications
  Future<void> clearAllNewEpisodes() async {
    state = state.copyWith(newEpisodeCounts: {});
    await _saveState();
  }
}

/// Provider for new episode notifications
final newEpisodeNotificationsProvider =
    NotifierProvider<NewEpisodeNotificationsNotifier, NewEpisodeNotificationsState>(
  NewEpisodeNotificationsNotifier.new,
);

/// Provider for new episode count for a specific show
final newEpisodeCountProvider = Provider.family<int, int>((ref, showId) {
  final notifications = ref.watch(newEpisodeNotificationsProvider);
  return notifications.getNewCount(showId);
});

/// Provider for total new episodes across all favorites
final totalNewEpisodesProvider = Provider<int>((ref) {
  final notifications = ref.watch(newEpisodeNotificationsProvider);
  return notifications.totalNewEpisodes;
});
