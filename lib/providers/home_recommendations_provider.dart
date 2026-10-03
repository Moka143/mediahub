import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/home_recommendation.dart';
import '../models/movie.dart';
import '../models/show.dart';
import '../services/app_logger.dart';
import 'favorites_provider.dart';
import 'shows_provider.dart';
import 'tmdb_synced_ids.dart';
import 'watch_progress_provider.dart';
import 'watchlist_provider.dart';

const _maxFetchSeeds = 2;
const _maxItems = 14;

/// Calendar-day index so the row is stable all day and advances tomorrow.
@visibleForTesting
int homeRecDayIndex([DateTime? now]) {
  final d = (now ?? DateTime.now()).toLocal();
  return DateTime(
    d.year,
    d.month,
    d.day,
  ).difference(DateTime(2020, 1, 1)).inDays;
}

@visibleForTesting
List<T> rotateStartingAt<T>(List<T> items, int start) {
  if (items.isEmpty) return const [];
  final i = start % items.length;
  if (i == 0) return List<T>.from(items);
  return [...items.sublist(i), ...items.sublist(0, i)];
}

/// Slide through a long TMDB neighbor list so one favorite still
/// feels fresh. Step of 7 so consecutive days don't look identical.
@visibleForTesting
List<T> dailyWindow<T>(List<T> items, int dayIndex, int limit) {
  if (items.length <= limit) return items;
  final start = (dayIndex * 7) % items.length;
  return [for (var n = 0; n < limit; n++) items[(start + n) % items.length]];
}

/// Today's primary seed plus one backup, rotated through the whole
/// favorite pool. We only *fetch* these — not every favorite.
@visibleForTesting
List<({bool isShow, int id})> pickDailySeeds({
  required List<int> showIds,
  required List<int> movieIds,
  required int dayIndex,
  int maxSeeds = _maxFetchSeeds,
}) {
  final pool = <({bool isShow, int id})>[
    for (final id in showIds) (isShow: true, id: id),
    for (final id in movieIds) (isShow: false, id: id),
  ];
  if (pool.isEmpty) return const [];
  return rotateStartingAt(pool, dayIndex).take(maxSeeds).toList();
}

/// The ids the Home row depends on, as values: the provider below selects
/// these instead of watching whole states, so it refetches when one of them
/// changes — not on every watch-progress write (each playback tick replaced
/// the Continue Watching list), every library rescan, or every sync-status
/// flip, each of which used to cost 2–4 TMDB calls and blank the row.
@immutable
class _RecInputs {
  const _RecInputs({
    required this.favoriteShows,
    required this.favoriteMovies,
    required this.watchlistShows,
    required this.watchlistMovies,
    required this.watchingShows,
    required this.watchingMovies,
    required this.watchedMovies,
  });

  final TmdbIds favoriteShows;
  final TmdbIds favoriteMovies;
  final TmdbIds watchlistShows;
  final TmdbIds watchlistMovies;
  final TmdbIds watchingShows;
  final TmdbIds watchingMovies;
  final TmdbIds watchedMovies;

  @override
  bool operator ==(Object other) =>
      other is _RecInputs &&
      other.favoriteShows == favoriteShows &&
      other.favoriteMovies == favoriteMovies &&
      other.watchlistShows == watchlistShows &&
      other.watchlistMovies == watchlistMovies &&
      other.watchingShows == watchingShows &&
      other.watchingMovies == watchingMovies &&
      other.watchedMovies == watchedMovies;

  @override
  int get hashCode => Object.hash(
    favoriteShows,
    favoriteMovies,
    watchlistShows,
    watchlistMovies,
    watchingShows,
    watchingMovies,
    watchedMovies,
  );
}

final _recInputsProvider = Provider<_RecInputs>((ref) {
  final fav = ref.watch(favoritesProvider);
  final watchlist = ref.watch(watchlistProvider);
  final watching = ref.watch(continueWatchingProvider);
  return _RecInputs(
    favoriteShows: TmdbIds(fav.favoriteIds),
    favoriteMovies: TmdbIds(fav.favoriteMovieIds),
    watchlistShows: TmdbIds(watchlist.showIds),
    watchlistMovies: TmdbIds(watchlist.movieIds),
    watchingShows: TmdbIds(watching.map((p) => p.showId).nonNulls),
    watchingMovies: TmdbIds(watching.map((p) => p.movieId).nonNulls),
    watchedMovies: TmdbIds(ref.watch(watchedIndexProvider).watchedMovieIds),
  );
});

/// TMDB has no personal recs endpoint. Each calendar day we pick one
/// favorite as the "because you liked" seed (plus a backup if that
/// list is thin) and window the neighbors so the row isn't frozen.
final homeRecommendationsProvider = FutureProvider<HomeRecommendationFeed?>((
  ref,
) async {
  // `select` compares with `==`, so a rebuild of the inputs that produced
  // the same ids does not reach this provider.
  final inputs = ref.watch(_recInputsProvider.select((i) => i));
  final tmdb = ref.watch(tmdbApiServiceProvider);
  final day = homeRecDayIndex();

  // Names are only for the header. Read, not watched: a name arriving later
  // must not refetch the row.
  final fav = ref.read(favoritesProvider);
  final watching = ref.read(continueWatchingProvider);
  final showNames = <int, String>{
    for (final p in watching)
      if (p.showId != null && (p.showName?.isNotEmpty ?? false))
        p.showId!: p.showName!,
    for (final e in fav.cachedShows.entries) e.key: e.value.name,
  };
  final movieNames = <int, String>{
    for (final p in watching)
      if (p.movieId != null && (p.showName?.isNotEmpty ?? false))
        p.movieId!: p.showName!,
    for (final e in fav.cachedMovies.entries) e.key: e.value.title,
  };

  // Favorites seed the row; with none, whatever is being watched does.
  var showIds = inputs.favoriteShows.ids;
  var movieIds = inputs.favoriteMovies.ids;
  if (showIds.isEmpty && movieIds.isEmpty) {
    showIds = inputs.watchingShows.ids;
    movieIds = inputs.watchingMovies.ids;
  }

  final seeds = pickDailySeeds(
    showIds: showIds,
    movieIds: movieIds,
    dayIndex: day,
  );
  if (seeds.isEmpty) return null;

  final showBatches = <({int id, String name, List<Show> recs})>[];
  final movieBatches = <({int id, String name, List<Movie> recs})>[];

  for (final seed in seeds) {
    if (seed.isShow) {
      try {
        final recs = await tmdb.getRecommendedShows(seed.id);
        var name = showNames[seed.id];
        if (name == null || name.isEmpty) {
          try {
            name = (await tmdb.getShowDetails(seed.id)).name;
          } catch (_) {
            name = 'this show';
          }
        }
        showBatches.add((id: seed.id, name: name, recs: recs));
      } catch (e) {
        // Skip this seed; other seeds still produce rows.
        AppLog.w('[Home] show recommendations for ${seed.id} failed: $e');
      }
    } else {
      try {
        final recs = await tmdb.getRecommendedMovies(seed.id);
        var name = movieNames[seed.id];
        if (name == null || name.isEmpty) {
          try {
            name = (await tmdb.getMovieDetails(seed.id)).title;
          } catch (_) {
            name = 'this movie';
          }
        }
        movieBatches.add((id: seed.id, name: name, recs: recs));
      } catch (e) {
        AppLog.w('[Home] movie recommendations for ${seed.id} failed: $e');
      }
    }
  }

  return buildHomeRecommendationFeed(
    showSeeds: showBatches,
    movieSeeds: movieBatches,
    excludeShowIds: {
      ...inputs.favoriteShows.ids,
      ...inputs.watchlistShows.ids,
      ...inputs.watchingShows.ids,
    },
    excludeMovieIds: {
      ...inputs.favoriteMovies.ids,
      ...inputs.watchlistMovies.ids,
      ...inputs.watchedMovies.ids,
      ...inputs.watchingMovies.ids,
    },
    dayIndex: day,
  );
});

/// Merge today's seed lists, drop titles the user already has, then
/// take a deterministic daily window so a single favorite still moves.
@visibleForTesting
HomeRecommendationFeed? buildHomeRecommendationFeed({
  required List<({int id, String name, List<Show> recs})> showSeeds,
  required List<({int id, String name, List<Movie> recs})> movieSeeds,
  required Set<int> excludeShowIds,
  required Set<int> excludeMovieIds,
  int dayIndex = 0,
  int limit = _maxItems,
}) {
  final seenShows = {...excludeShowIds};
  final seenMovies = {...excludeMovieIds};
  final showQueues = [for (final s in showSeeds) List<Show>.from(s.recs)];
  final movieQueues = [for (final s in movieSeeds) List<Movie>.from(s.recs)];

  final items = <HomeRecTile>[];
  String? because;

  var progressed = true;
  while (progressed) {
    progressed = false;

    for (var i = 0; i < showQueues.length; i++) {
      while (showQueues[i].isNotEmpty) {
        final show = showQueues[i].removeAt(0);
        if (!seenShows.add(show.id)) continue;
        items.add(HomeRecTile.show(show));
        because ??= showSeeds[i].name;
        progressed = true;
        break;
      }
    }

    for (var i = 0; i < movieQueues.length; i++) {
      while (movieQueues[i].isNotEmpty) {
        final movie = movieQueues[i].removeAt(0);
        if (!seenMovies.add(movie.id)) continue;
        items.add(HomeRecTile.movie(movie));
        because ??= movieSeeds[i].name;
        progressed = true;
        break;
      }
    }
  }

  if (items.isEmpty || because == null || because.isEmpty) return null;
  return HomeRecommendationFeed(
    becauseTitle: because,
    items: dailyWindow(items, dayIndex, limit),
  );
}
