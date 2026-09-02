import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/movie.dart';
import '../models/show.dart';
import '../services/app_logger.dart';
import 'favorites_provider.dart';
import 'shows_provider.dart';
import 'watch_progress_provider.dart';
import 'watchlist_provider.dart';

/// A TMDB title recommended because the user favorited (or is watching)
/// another title. Show and movie share one row on Home.
class HomeRecTile {
  const HomeRecTile.show(this.show) : movie = null;
  const HomeRecTile.movie(this.movie) : show = null;

  final Show? show;
  final Movie? movie;

  bool get isShow => show != null;
  int get id => show?.id ?? movie!.id;
  String get title => show?.name ?? movie!.title;
  String? get year => show?.year ?? movie!.year;
  String? get posterUrl => show?.posterUrl ?? movie!.posterUrl;
}

class HomeRecommendationFeed {
  const HomeRecommendationFeed({
    required this.becauseTitle,
    required this.items,
  });

  /// Seed title used in the section header — "Because you liked Lioness".
  final String becauseTitle;
  final List<HomeRecTile> items;
}

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

/// TMDB has no personal recs endpoint. Each calendar day we pick one
/// favorite as the "because you liked" seed (plus a backup if that
/// list is thin) and window the neighbors so the row isn't frozen.
final homeRecommendationsProvider = FutureProvider<HomeRecommendationFeed?>((
  ref,
) async {
  final fav = ref.watch(favoritesProvider);
  final watchlist = ref.watch(watchlistProvider);
  final continueWatching = ref.watch(continueWatchingProvider);
  final watchedMovies = ref.watch(watchedIndexProvider).watchedMovieIds;
  final tmdb = ref.read(tmdbApiServiceProvider);
  final day = homeRecDayIndex();

  final showIds = <int>[];
  final movieIds = <int>[];
  final showNames = <int, String>{};
  final movieNames = <int, String>{};

  void addShow(int id, String? name) {
    if (showIds.contains(id)) return;
    showIds.add(id);
    if (name != null && name.isNotEmpty) showNames[id] = name;
  }

  void addMovie(int id, String? name) {
    if (movieIds.contains(id)) return;
    movieIds.add(id);
    if (name != null && name.isNotEmpty) movieNames[id] = name;
  }

  for (final id in fav.favoriteIds) {
    addShow(id, fav.cachedShows[id]?.name);
  }
  for (final id in fav.favoriteMovieIds) {
    addMovie(id, fav.cachedMovies[id]?.title);
  }

  if (showIds.isEmpty && movieIds.isEmpty) {
    for (final p in continueWatching) {
      if (p.showId != null) addShow(p.showId!, p.showName);
      if (p.movieId != null) addMovie(p.movieId!, p.showName);
    }
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

  final cwShowIds = {
    for (final p in continueWatching)
      if (p.showId != null) p.showId!,
  };
  final cwMovieIds = {
    for (final p in continueWatching)
      if (p.movieId != null) p.movieId!,
  };

  return buildHomeRecommendationFeed(
    showSeeds: showBatches,
    movieSeeds: movieBatches,
    excludeShowIds: {...fav.favoriteIds, ...watchlist.showIds, ...cwShowIds},
    excludeMovieIds: {
      ...fav.favoriteMovieIds,
      ...watchlist.movieIds,
      ...watchedMovies,
      ...cwMovieIds,
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
