import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/movie.dart';
import '../models/show.dart';
import '../services/tmdb_account_service.dart';
import '../services/tmdb_api_service.dart';
import 'shows_provider.dart';
import 'movies_provider.dart';
import 'settings_provider.dart';
import 'tmdb_account_provider.dart';

/// Key for storing favorites in SharedPreferences (TV — kept for back-compat).
const String _favoritesKey = 'favorite_shows';
const String _favoriteMoviesKey = 'favorite_movies';
const String _lastCheckedKey = 'favorites_last_checked';
const String _newEpisodesKey = 'new_episodes_count';

/// State class for favorites — TV shows and movies.
class FavoritesState {
  final Set<int> favoriteIds; // TV shows
  final Set<int> favoriteMovieIds; // movies
  final Map<int, Show> cachedShows;
  final Map<int, Movie> cachedMovies;
  final bool isLoading;
  final bool isSyncing;
  final String? error;

  const FavoritesState({
    this.favoriteIds = const {},
    this.favoriteMovieIds = const {},
    this.cachedShows = const {},
    this.cachedMovies = const {},
    this.isLoading = false,
    this.isSyncing = false,
    this.error,
  });

  FavoritesState copyWith({
    Set<int>? favoriteIds,
    Set<int>? favoriteMovieIds,
    Map<int, Show>? cachedShows,
    Map<int, Movie>? cachedMovies,
    bool? isLoading,
    bool? isSyncing,
    String? error,
  }) {
    return FavoritesState(
      favoriteIds: favoriteIds ?? this.favoriteIds,
      favoriteMovieIds: favoriteMovieIds ?? this.favoriteMovieIds,
      cachedShows: cachedShows ?? this.cachedShows,
      cachedMovies: cachedMovies ?? this.cachedMovies,
      isLoading: isLoading ?? this.isLoading,
      isSyncing: isSyncing ?? this.isSyncing,
      error: error,
    );
  }

  bool isFavorite(int showId) => favoriteIds.contains(showId);
  bool isMovieFavorite(int movieId) => favoriteMovieIds.contains(movieId);
}

/// Notifier for managing favorites — also pushes mutations to TMDB when the
/// user is signed in. On TMDB-side error we DO NOT roll back the optimistic
/// local update; instead the next sync will reconcile, so a transient
/// network blip doesn't make the heart icon flicker.
class FavoritesNotifier extends Notifier<FavoritesState> {
  @override
  FavoritesState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return _loadFromPrefs(prefs);
  }

  TmdbApiService get _tmdbService => ref.read(tmdbApiServiceProvider);
  TmdbAccountService get _accountService =>
      ref.read(tmdbAccountServiceProvider);
  TmdbSession? get _session => ref.read(tmdbSessionProvider);

  FavoritesState _loadFromPrefs(SharedPreferences prefs) {
    Set<int> tv = const {};
    Set<int> movies = const {};
    try {
      final tvJson = prefs.getString(_favoritesKey);
      if (tvJson != null) {
        tv = (jsonDecode(tvJson) as List<dynamic>).cast<int>().toSet();
      }
    } catch (_) {}
    try {
      final mvJson = prefs.getString(_favoriteMoviesKey);
      if (mvJson != null) {
        movies = (jsonDecode(mvJson) as List<dynamic>).cast<int>().toSet();
      }
    } catch (_) {}
    return FavoritesState(favoriteIds: tv, favoriteMovieIds: movies);
  }

  Future<void> _saveTv() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_favoritesKey, jsonEncode(state.favoriteIds.toList()));
  }

  Future<void> _saveMovies() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(
      _favoriteMoviesKey,
      jsonEncode(state.favoriteMovieIds.toList()),
    );
  }

  // ---------------- TV ----------------

  Future<void> addFavorite(int showId, {Show? show}) async {
    final newIds = Set<int>.from(state.favoriteIds)..add(showId);
    final newCache = show != null
        ? (Map<int, Show>.from(state.cachedShows)..[showId] = show)
        : null;
    state = state.copyWith(favoriteIds: newIds, cachedShows: newCache);
    await _saveTv();
    _pushToTmdb(TmdbMediaType.tv, showId, true);
  }

  Future<void> removeFavorite(int showId) async {
    final newIds = Set<int>.from(state.favoriteIds)..remove(showId);
    final newCache = Map<int, Show>.from(state.cachedShows)..remove(showId);
    state = state.copyWith(favoriteIds: newIds, cachedShows: newCache);
    await _saveTv();
    _pushToTmdb(TmdbMediaType.tv, showId, false);
  }

  Future<void> toggleFavorite(int showId, {Show? show}) async {
    if (state.favoriteIds.contains(showId)) {
      await removeFavorite(showId);
    } else {
      await addFavorite(showId, show: show);
    }
  }

  bool isFavorite(int showId) => state.favoriteIds.contains(showId);
  Show? getCachedShow(int showId) => state.cachedShows[showId];

  // ---------------- Movies ----------------

  Future<void> addMovieFavorite(int movieId, {Movie? movie}) async {
    final newIds = Set<int>.from(state.favoriteMovieIds)..add(movieId);
    final newCache = movie != null
        ? (Map<int, Movie>.from(state.cachedMovies)..[movieId] = movie)
        : null;
    state = state.copyWith(
      favoriteMovieIds: newIds,
      cachedMovies: newCache,
    );
    await _saveMovies();
    _pushToTmdb(TmdbMediaType.movie, movieId, true);
  }

  Future<void> removeMovieFavorite(int movieId) async {
    final newIds = Set<int>.from(state.favoriteMovieIds)..remove(movieId);
    final newCache = Map<int, Movie>.from(state.cachedMovies)..remove(movieId);
    state = state.copyWith(
      favoriteMovieIds: newIds,
      cachedMovies: newCache,
    );
    await _saveMovies();
    _pushToTmdb(TmdbMediaType.movie, movieId, false);
  }

  Future<void> toggleMovieFavorite(int movieId, {Movie? movie}) async {
    if (state.favoriteMovieIds.contains(movieId)) {
      await removeMovieFavorite(movieId);
    } else {
      await addMovieFavorite(movieId, movie: movie);
    }
  }

  bool isMovieFavorite(int movieId) =>
      state.favoriteMovieIds.contains(movieId);

  // ---------------- TMDB push & sync ----------------

  void _pushToTmdb(TmdbMediaType type, int id, bool favorite) {
    final s = _session;
    if (s == null) return;
    // Fire-and-forget. Reconciliation happens on next syncFromTmdb.
    () async {
      try {
        await _accountService.setFavorite(
          accountId: s.account.id,
          sessionId: s.sessionId,
          mediaType: type,
          mediaId: id,
          favorite: favorite,
        );
      } catch (e) {
        debugPrint('TMDB favorite push failed for $type:$id ($favorite): $e');
      }
    }();
  }

  /// Pull authoritative favorite lists from TMDB and replace local state.
  /// Called on sign-in and from the user's manual refresh button.
  Future<void> syncFromTmdb({bool pushLocalFirst = false}) async {
    final s = _session;
    if (s == null) return;
    state = state.copyWith(isSyncing: true, error: null);
    try {
      if (pushLocalFirst) {
        // Union: ensure anything we had locally also lives on TMDB before we
        // overwrite local with the server's view.
        for (final id in state.favoriteIds) {
          try {
            await _accountService.setFavorite(
              accountId: s.account.id,
              sessionId: s.sessionId,
              mediaType: TmdbMediaType.tv,
              mediaId: id,
              favorite: true,
            );
          } catch (_) {}
        }
        for (final id in state.favoriteMovieIds) {
          try {
            await _accountService.setFavorite(
              accountId: s.account.id,
              sessionId: s.sessionId,
              mediaType: TmdbMediaType.movie,
              mediaId: id,
              favorite: true,
            );
          } catch (_) {}
        }
      }

      final tvIds = await _accountService.getFavoriteShowIds(
        accountId: s.account.id,
        sessionId: s.sessionId,
      );
      final movieIds = await _accountService.getFavoriteMovieIds(
        accountId: s.account.id,
        sessionId: s.sessionId,
      );
      // Drop cache entries that disappeared server-side; keep ones still
      // favorited so the UI doesn't have to re-fetch metadata.
      final newShowCache = {
        for (final e in state.cachedShows.entries)
          if (tvIds.contains(e.key)) e.key: e.value,
      };
      final newMovieCache = {
        for (final e in state.cachedMovies.entries)
          if (movieIds.contains(e.key)) e.key: e.value,
      };
      state = state.copyWith(
        favoriteIds: tvIds,
        favoriteMovieIds: movieIds,
        cachedShows: newShowCache,
        cachedMovies: newMovieCache,
        isSyncing: false,
      );
      await _saveTv();
      await _saveMovies();
    } catch (e) {
      state = state.copyWith(isSyncing: false, error: e.toString());
    }
  }

  /// Load full show details for favorites
  Future<void> loadFavoriteDetails() async {
    if (state.favoriteIds.isEmpty) return;
    state = state.copyWith(isLoading: true);
    try {
      final newCache = Map<int, Show>.from(state.cachedShows);
      for (final id in state.favoriteIds) {
        if (!newCache.containsKey(id)) {
          try {
            newCache[id] = await _tmdbService.getShowDetails(id);
          } catch (_) {}
        }
      }
      state = state.copyWith(cachedShows: newCache, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  Future<void> clearFavorites() async {
    final tv = Set<int>.from(state.favoriteIds);
    final movies = Set<int>.from(state.favoriteMovieIds);
    state = state.copyWith(
      favoriteIds: const {},
      favoriteMovieIds: const {},
      cachedShows: const {},
      cachedMovies: const {},
    );
    await _saveTv();
    await _saveMovies();
    // Mirror the deletions to TMDB if we're signed in.
    final s = _session;
    if (s == null) return;
    for (final id in tv) {
      _pushToTmdb(TmdbMediaType.tv, id, false);
    }
    for (final id in movies) {
      _pushToTmdb(TmdbMediaType.movie, id, false);
    }
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

/// Check if a movie is favorited
final isMovieFavoriteProvider = Provider.family<bool, int>((ref, movieId) {
  final favorites = ref.watch(favoritesProvider);
  return favorites.favoriteMovieIds.contains(movieId);
});

/// Provider for favorite show details (loads full show info)
final favoriteShowsProvider = FutureProvider<List<Show>>((ref) async {
  final favorites = ref.watch(favoritesProvider);
  final tmdbService = ref.read(tmdbApiServiceProvider);
  if (favorites.favoriteIds.isEmpty) return [];
  final List<Show> shows = [];
  for (final id in favorites.favoriteIds) {
    try {
      shows.add(await tmdbService.getShowDetails(id));
    } catch (_) {}
  }
  return shows;
});

/// Provider for favorite movie details (loads full movie info)
final favoriteMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final favorites = ref.watch(favoritesProvider);
  final tmdbService = ref.read(tmdbApiServiceProvider);
  if (favorites.favoriteMovieIds.isEmpty) return [];
  final List<Movie> movies = [];
  for (final id in favorites.favoriteMovieIds) {
    try {
      movies.add(await tmdbService.getMovieDetails(id));
    } catch (_) {}
  }
  return movies;
});

/// Provider for upcoming episodes from favorite shows
final upcomingEpisodesProvider = FutureProvider<List<UpcomingEpisode>>((
  ref,
) async {
  final favorites = ref.watch(favoritesProvider);
  final tmdbService = ref.read(tmdbApiServiceProvider);
  if (favorites.favoriteIds.isEmpty) return [];
  final List<UpcomingEpisode> upcoming = [];
  for (final showId in favorites.favoriteIds) {
    try {
      final show = await tmdbService.getShowDetails(showId);
      if (show.nextEpisodeToAir != null && show.inProduction) {
        upcoming.add(
          UpcomingEpisode(show: show, airDate: show.nextEpisodeToAir!),
        );
      }
    } catch (_) {}
  }
  upcoming.sort((a, b) => a.airDate.compareTo(b.airDate));
  return upcoming;
});

class UpcomingEpisode {
  final Show show;
  final String airDate;
  UpcomingEpisode({required this.show, required this.airDate});

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
// New Episode Notification System (unchanged below)
// ============================================================================

class NewEpisodeNotificationsState {
  final Map<int, int> newEpisodeCounts;
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

class NewEpisodeNotificationsNotifier
    extends Notifier<NewEpisodeNotificationsState> {
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
    } catch (_) {
      return const NewEpisodeNotificationsState();
    }
  }

  Future<void> _saveState() async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (state.lastChecked != null) {
      await prefs.setString(
        _lastCheckedKey,
        state.lastChecked!.toIso8601String(),
      );
    }
    final countsJson = jsonEncode(
      state.newEpisodeCounts.map((k, v) => MapEntry(k.toString(), v)),
    );
    await prefs.setString(_newEpisodesKey, countsJson);
  }

  Future<void> checkForNewEpisodes() async {
    final favorites = ref.read(favoritesProvider);
    final tmdbService = ref.read(tmdbApiServiceProvider);
    if (favorites.favoriteIds.isEmpty) return;

    final now = DateTime.now();
    final lastChecked =
        state.lastChecked ?? now.subtract(const Duration(days: 7));
    final newCounts = <int, int>{};

    for (final showId in favorites.favoriteIds) {
      try {
        final show = await tmdbService.getShowDetails(showId);
        final numSeasons = show.numberOfSeasons ?? 0;
        int newCount = 0;
        if (numSeasons > 0) {
          try {
            final episodes = await tmdbService.getSeasonEpisodes(
              showId,
              numSeasons,
            );
            for (final episode in episodes) {
              if (episode.airDate == null) continue;
              final airDate = DateTime.tryParse(episode.airDate!);
              if (airDate == null) continue;
              if (airDate.isAfter(lastChecked) && airDate.isBefore(now)) {
                newCount++;
              }
            }
          } catch (_) {}
        }
        if (newCount > 0) newCounts[showId] = newCount;
      } catch (_) {}
    }

    state = state.copyWith(newEpisodeCounts: newCounts, lastChecked: now);
    await _saveState();
  }

  Future<void> clearNewEpisodes(int showId) async {
    final newCounts = Map<int, int>.from(state.newEpisodeCounts);
    newCounts.remove(showId);
    state = state.copyWith(newEpisodeCounts: newCounts);
    await _saveState();
  }

  Future<void> clearAllNewEpisodes() async {
    state = state.copyWith(newEpisodeCounts: {});
    await _saveState();
  }
}

final newEpisodeNotificationsProvider =
    NotifierProvider<
      NewEpisodeNotificationsNotifier,
      NewEpisodeNotificationsState
    >(NewEpisodeNotificationsNotifier.new);

final newEpisodeCountProvider = Provider.family<int, int>((ref, showId) {
  final notifications = ref.watch(newEpisodeNotificationsProvider);
  return notifications.getNewCount(showId);
});

final totalNewEpisodesProvider = Provider<int>((ref) {
  final notifications = ref.watch(newEpisodeNotificationsProvider);
  return notifications.totalNewEpisodes;
});
