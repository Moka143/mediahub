import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/movie.dart';
import '../models/tmdb_genres.dart';
import '../providers/movies_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/tmdb_api_service.dart';
import '../widgets/common/paged_browse_view.dart';
import '../widgets/media/hue_backdrop.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/mediahub_spotlight.dart';
import 'movie_details_screen.dart';
import 'settings_screen.dart';

/// Movies browse — a paged poster wall over TMDB's movie feeds, narrowed by
/// genre through `discover/movie`. The paging, search and states are
/// [PagedBrowseView]'s; this file says only what is movie-specific.
class MoviesScreen extends StatelessWidget {
  const MoviesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PagedBrowseView<Movie>(
      config: const MoviesBrowseConfig(),
      onOpenSettings: (context) => unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
      ),
    );
  }
}

/// What the Movies tab browses.
@visibleForTesting
class MoviesBrowseConfig extends BrowseConfig<Movie> {
  const MoviesBrowseConfig();

  static const trending = BrowseFeed('Trending');
  static const popular = BrowseFeed('Popular');
  static const topRated = BrowseFeed('Top rated');
  static const newReleases = BrowseFeed('New releases');

  @override
  String get keyPrefix => 'movies';

  @override
  String get noun => 'movies';

  @override
  String get searchHint => 'Search movies…';

  /// Built once, so the picker's choices keep their identity across builds.
  static final List<BrowseGenre> _genres = BrowseGenre.listFrom(
    tmdbMovieGenres,
  );

  @override
  List<BrowseGenre> get genres => _genres;

  @override
  List<BrowseFeed> get feeds => const [
    trending,
    popular,
    topRated,
    newReleases,
  ];

  /// The `discover/movie` query for [feed] under a genre filter — see
  /// [discoverQueryFor].
  @visibleForTesting
  static DiscoverQuery discoverQuery(BrowseFeed feed, {DateTime? now}) =>
      discoverQueryFor(
        feed,
        trending: trending,
        topRated: topRated,
        latest: newReleases,
        latestSortBy: 'release_date.desc',
        topRatedMinVotes: 300,
        now: now,
      );

  @override
  Future<List<Movie>> fetchPage(
    TmdbApiService tmdb, {
    required BrowseFeed feed,
    required BrowseGenre genre,
    required int page,
  }) {
    if (genre.isAll) {
      if (identical(feed, popular)) return tmdb.getPopularMovies(page: page);
      if (identical(feed, topRated)) return tmdb.getTopRatedMovies(page: page);
      if (identical(feed, newReleases)) {
        return tmdb.getUpcomingMovies(page: page);
      }
      return tmdb.getTrendingMovies(page: page);
    }
    final query = discoverQuery(feed);
    return tmdb.discoverMovies(
      page: page,
      withGenres: genre.ids.join(','),
      sortBy: query.sortBy,
      year: query.year,
      voteCountGte: query.minVotes,
    );
  }

  @override
  String watchSearchQuery(WidgetRef ref) => ref.watch(movieSearchQueryProvider);

  @override
  String readSearchQuery(WidgetRef ref) => ref.read(movieSearchQueryProvider);

  @override
  void setSearchQuery(WidgetRef ref, String query) =>
      ref.read(movieSearchQueryProvider.notifier).set(query);

  @override
  AsyncValue<List<Movie>> watchSearchResults(WidgetRef ref) =>
      ref.watch(movieSearchResultsProvider);

  @override
  int idOf(Movie item) => item.id;

  void _open(BuildContext context, Movie movie, {bool pickSource = false}) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MovieDetailsScreen(
            movie: movie,
            autoOpenTorrentPicker: pickSource,
          ),
        ),
      ),
    );
  }

  @override
  Widget buildCard(BuildContext context, Movie item) {
    // Each card watches its own watched flag, so a mark on one title
    // rebuilds one card, not the grid.
    return Consumer(
      builder: (context, ref, _) => MediaPosterCard.movie(
        item,
        isWatched: ref.watch(isMovieWatchedProvider(item.id)),
        onTap: () => _open(context, item),
      ),
    );
  }

  @override
  Widget buildSpotlight(
    BuildContext context,
    Movie item, {
    required BrowseFeed feed,
    required BrowseGenre genre,
  }) {
    return MediaHubSpotlight(
      title: item.title,
      year: item.year,
      // The chip the feed is filtered by, else the title's own first genre:
      // by name on a details record, by id on a list record.
      genre: genre.isAll
          ? (item.genres.isNotEmpty
                ? item.genres.first
                : firstGenreName(item.genreIds, tv: false))
          : genre.label,
      rating: ratingLabel(item.voteAverage, voteCount: item.voteCount),
      hue: hueForId(item.id),
      metaSuffix: item.runtimeFormatted?.toUpperCase() ?? 'MOVIE',
      feedLabel: genre.isAll ? feed.label : '${feed.label} · ${genre.label}',
      backdropUrl: item.backdropUrl,
      posterUrl: item.posterUrl,
      onPrimaryTap: () => _open(context, item, pickSource: true),
      onSecondaryTap: () => _open(context, item),
    );
  }
}
