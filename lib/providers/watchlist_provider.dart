import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/movie.dart';
import '../models/show.dart';
import '../services/tmdb_account_service.dart';
import 'shows_provider.dart';
import 'tmdb_synced_ids.dart';

/// Watchlist state — TV shows and movies the user wants to watch later.
/// Mirrors the same shape as favorites and rides the same TMDB account.
class WatchlistState implements TmdbIdSetsState {
  const WatchlistState({
    this.showIds = const {},
    this.movieIds = const {},
    this.isSyncing = false,
    this.error,
  });

  final Set<int> showIds;
  final Set<int> movieIds;

  @override
  final bool isSyncing;

  @override
  final String? error;

  @override
  Set<int> get syncedShowIds => showIds;

  @override
  Set<int> get syncedMovieIds => movieIds;
}

/// The watchlist, mirrored to the TMDB account's watchlist when signed in —
/// see [TmdbSyncedIdsNotifier].
class WatchlistNotifier extends TmdbSyncedIdsNotifier<WatchlistState> {
  @override
  TmdbAccountList get list => TmdbAccountList.watchlist;

  @override
  WatchlistState build() {
    final ids = loadIds();
    return WatchlistState(showIds: ids.shows, movieIds: ids.movies);
  }

  @override
  WatchlistState stateFor({
    required Set<int> shows,
    required Set<int> movies,
    required bool isSyncing,
    String? error,
  }) => WatchlistState(
    showIds: shows,
    movieIds: movies,
    isSyncing: isSyncing,
    error: error,
  );

  Future<void> toggleShow(int id) =>
      setItem(TmdbMediaType.tv, id, on: !state.showIds.contains(id));

  Future<void> toggleMovie(int id) =>
      setItem(TmdbMediaType.movie, id, on: !state.movieIds.contains(id));
}

final watchlistProvider = NotifierProvider<WatchlistNotifier, WatchlistState>(
  WatchlistNotifier.new,
);

final isOnWatchlistProvider = Provider.family<bool, int>((ref, id) {
  return ref.watch(watchlistProvider.select((s) => s.showIds.contains(id)));
});

final isMovieOnWatchlistProvider = Provider.family<bool, int>((ref, id) {
  return ref.watch(watchlistProvider.select((s) => s.movieIds.contains(id)));
});

/// Watchlist shows with full details. Rebuilds when the ids change, not on
/// every sync-status flip.
final watchlistShowsProvider = FutureProvider<List<Show>>((ref) async {
  final ids = ref.watch(watchlistProvider.select((s) => TmdbIds(s.showIds)));
  return fetchShowsForIds(ref.watch(tmdbApiServiceProvider), ids);
});

/// Watchlist movies with full details.
final watchlistMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final ids = ref.watch(watchlistProvider.select((s) => TmdbIds(s.movieIds)));
  return fetchMoviesForIds(ref.watch(tmdbApiServiceProvider), ids);
});
