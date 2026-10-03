import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/movie.dart';
import '../models/show.dart';
import '../models/upcoming_episode.dart';
import '../services/tmdb_account_service.dart';
import 'settings_provider.dart';
import 'shows_provider.dart';
import 'tmdb_synced_ids.dart';

/// Keys of the removed new-episode counter. Nothing reads them; they are
/// dropped once so they do not sit in every user's prefs forever.
const _retiredKeys = ['favorites_last_checked', 'new_episodes_count'];

/// State class for favorites — TV shows and movies.
class FavoritesState implements TmdbIdSetsState {
  final Set<int> favoriteIds; // TV shows
  final Set<int> favoriteMovieIds; // movies

  /// Details handed over when a title was favorited, so the Home row can
  /// name it without a request. Not a complete cache.
  final Map<int, Show> cachedShows;
  final Map<int, Movie> cachedMovies;

  @override
  final bool isSyncing;

  @override
  final String? error;

  const FavoritesState({
    this.favoriteIds = const {},
    this.favoriteMovieIds = const {},
    this.cachedShows = const {},
    this.cachedMovies = const {},
    this.isSyncing = false,
    this.error,
  });

  @override
  Set<int> get syncedShowIds => favoriteIds;

  @override
  Set<int> get syncedMovieIds => favoriteMovieIds;
}

/// Notifier for managing favorites, mirrored to the TMDB account's favorites
/// when signed in — see [TmdbSyncedIdsNotifier] for how pushes, retries and
/// the sync behave.
class FavoritesNotifier extends TmdbSyncedIdsNotifier<FavoritesState> {
  @override
  TmdbAccountList get list => TmdbAccountList.favorites;

  @override
  FavoritesState build() {
    final ids = loadIds();
    final prefs = ref.watch(sharedPreferencesProvider);
    for (final key in _retiredKeys) {
      if (prefs.containsKey(key)) unawaited(prefs.remove(key));
    }
    return FavoritesState(favoriteIds: ids.shows, favoriteMovieIds: ids.movies);
  }

  @override
  FavoritesState stateFor({
    required Set<int> shows,
    required Set<int> movies,
    required bool isSyncing,
    String? error,
  }) {
    // Cache entries follow the ids: a title that left the list leaves the
    // cache too, and nothing has to re-fetch the ones that stayed.
    return FavoritesState(
      favoriteIds: shows,
      favoriteMovieIds: movies,
      cachedShows: {
        for (final e in state.cachedShows.entries)
          if (shows.contains(e.key)) e.key: e.value,
      },
      cachedMovies: {
        for (final e in state.cachedMovies.entries)
          if (movies.contains(e.key)) e.key: e.value,
      },
      isSyncing: isSyncing,
      error: error,
    );
  }

  /// Favorite or un-favorite a show. [show], when given, is kept so the
  /// title can be shown without a request.
  Future<void> toggleFavorite(int showId, {Show? show}) async {
    final on = !state.favoriteIds.contains(showId);
    if (on && show != null) {
      state = _withCached(shows: {...state.cachedShows, showId: show});
    }
    await setItem(TmdbMediaType.tv, showId, on: on);
  }

  /// Favorite or un-favorite a movie.
  Future<void> toggleMovieFavorite(int movieId, {Movie? movie}) async {
    final on = !state.favoriteMovieIds.contains(movieId);
    if (on && movie != null) {
      state = _withCached(movies: {...state.cachedMovies, movieId: movie});
    }
    await setItem(TmdbMediaType.movie, movieId, on: on);
  }

  FavoritesState _withCached({
    Map<int, Show>? shows,
    Map<int, Movie>? movies,
  }) => FavoritesState(
    favoriteIds: state.favoriteIds,
    favoriteMovieIds: state.favoriteMovieIds,
    cachedShows: shows ?? state.cachedShows,
    cachedMovies: movies ?? state.cachedMovies,
    isSyncing: state.isSyncing,
    error: state.error,
  );
}

/// Provider for managing favorite shows
final favoritesProvider = NotifierProvider<FavoritesNotifier, FavoritesState>(
  FavoritesNotifier.new,
);

/// Check if a show is favorited
final isFavoriteProvider = Provider.family<bool, int>((ref, showId) {
  return ref.watch(
    favoritesProvider.select((s) => s.favoriteIds.contains(showId)),
  );
});

/// Check if a movie is favorited
final isMovieFavoriteProvider = Provider.family<bool, int>((ref, movieId) {
  return ref.watch(
    favoritesProvider.select((s) => s.favoriteMovieIds.contains(movieId)),
  );
});

/// Favorite shows with full details, fetched in parallel. Rebuilds when the
/// favorite ids change — not on every sync-status flip.
final favoriteShowsProvider = FutureProvider<List<Show>>((ref) async {
  final ids = ref.watch(
    favoritesProvider.select((s) => TmdbIds(s.favoriteIds)),
  );
  return fetchShowsForIds(ref.watch(tmdbApiServiceProvider), ids);
});

/// Favorite movies with full details. See [favoriteShowsProvider].
final favoriteMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final ids = ref.watch(
    favoritesProvider.select((s) => TmdbIds(s.favoriteMovieIds)),
  );
  return fetchMoviesForIds(ref.watch(tmdbApiServiceProvider), ids);
});

/// Upcoming episodes of favorite shows, soonest first.
///
/// Built from [favoriteShowsProvider]'s details rather than fetching every
/// show a second time, and limited to dates still ahead — TMDB keeps a
/// `next_episode_to_air` around for a while after it has aired.
final upcomingEpisodesProvider = FutureProvider<List<UpcomingEpisode>>((
  ref,
) async {
  final shows = await ref.watch(favoriteShowsProvider.future);
  final now = DateTime.now();
  final upcoming = <UpcomingEpisode>[
    for (final show in shows)
      if (show.inProduction && show.nextEpisode?.airDate != null)
        UpcomingEpisode(show: show, airDate: show.nextEpisode!.airDate!),
  ].where((e) => e.daysUntilAirFrom(now) >= 0).toList();
  upcoming.sort((a, b) => a.airDate.compareTo(b.airDate));
  return upcoming;
});
