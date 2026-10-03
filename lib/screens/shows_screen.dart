import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/show.dart';
import '../models/tmdb_genres.dart';
import '../providers/shows_provider.dart';
import '../services/tmdb_api_service.dart';
import '../widgets/common/paged_browse_view.dart';
import '../widgets/media/hue_backdrop.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/mediahub_spotlight.dart';
import 'settings_screen.dart';
import 'show_details_screen.dart';

/// TV Shows browse — a paged poster wall over TMDB's TV feeds, narrowed by
/// genre through `discover/tv`. The paging, search and states are
/// [PagedBrowseView]'s; this file says only what is show-specific.
class ShowsScreen extends StatelessWidget {
  const ShowsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PagedBrowseView<Show>(
      config: const ShowsBrowseConfig(),
      onOpenSettings: (context) => unawaited(
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
      ),
    );
  }
}

/// What the TV Shows tab browses.
@visibleForTesting
class ShowsBrowseConfig extends BrowseConfig<Show> {
  const ShowsBrowseConfig();

  static const trending = BrowseFeed('Trending');
  static const popular = BrowseFeed('Popular');
  static const topRated = BrowseFeed('Top rated');
  static const onTheAir = BrowseFeed('On the air');

  @override
  String get keyPrefix => 'shows';

  @override
  String get noun => 'shows';

  @override
  String get searchHint => 'Search shows…';

  /// Built once, so the picker's choices keep their identity across builds.
  static final List<BrowseGenre> _genres = BrowseGenre.listFrom(tmdbTvGenres);

  @override
  List<BrowseGenre> get genres => _genres;

  @override
  List<BrowseFeed> get feeds => const [trending, popular, topRated, onTheAir];

  /// The `discover/tv` query for [feed] under a genre filter — see
  /// [discoverQueryFor].
  @visibleForTesting
  static DiscoverQuery discoverQuery(BrowseFeed feed, {DateTime? now}) =>
      discoverQueryFor(
        feed,
        trending: trending,
        topRated: topRated,
        latest: onTheAir,
        latestSortBy: 'first_air_date.desc',
        topRatedMinVotes: 200,
        now: now,
      );

  @override
  Future<List<Show>> fetchPage(
    TmdbApiService tmdb, {
    required BrowseFeed feed,
    required BrowseGenre genre,
    required int page,
  }) {
    if (genre.isAll) {
      if (identical(feed, popular)) return tmdb.getPopularShows(page: page);
      if (identical(feed, topRated)) return tmdb.getTopRatedShows(page: page);
      if (identical(feed, onTheAir)) return tmdb.getOnTheAirShows(page: page);
      return tmdb.getTrendingShows(page: page);
    }
    final query = discoverQuery(feed);
    return tmdb.discoverShows(
      page: page,
      withGenres: genre.ids.join(','),
      sortBy: query.sortBy,
      year: query.year,
      voteCountGte: query.minVotes,
    );
  }

  @override
  String watchSearchQuery(WidgetRef ref) => ref.watch(showSearchQueryProvider);

  @override
  String readSearchQuery(WidgetRef ref) => ref.read(showSearchQueryProvider);

  @override
  void setSearchQuery(WidgetRef ref, String query) =>
      ref.read(showSearchQueryProvider.notifier).set(query);

  @override
  AsyncValue<List<Show>> watchSearchResults(WidgetRef ref) =>
      ref.watch(showSearchResultsProvider);

  @override
  int idOf(Show item) => item.id;

  void _open(BuildContext context, Show show, {bool pickEpisode = false}) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ShowDetailsScreen(
            show: show,
            autoOpenEpisodesDrawer: pickEpisode,
          ),
        ),
      ),
    );
  }

  @override
  Widget buildCard(BuildContext context, Show item) =>
      MediaPosterCard.show(item, onTap: () => _open(context, item));

  @override
  Widget buildSpotlight(
    BuildContext context,
    Show item, {
    required BrowseFeed feed,
    required BrowseGenre genre,
  }) {
    return MediaHubSpotlight(
      title: item.name,
      year: item.year,
      genre: genre.isAll
          ? (item.genres.isNotEmpty
                ? item.genres.first
                : firstGenreName(item.genreIds, tv: true))
          : genre.label,
      rating: ratingLabel(item.voteAverage, voteCount: item.voteCount),
      hue: hueForId(item.id),
      metaSuffix: 'TV SERIES',
      feedLabel: genre.isAll ? feed.label : '${feed.label} · ${genre.label}',
      backdropUrl: item.backdropUrl,
      posterUrl: item.posterUrl,
      onPrimaryTap: () => _open(context, item, pickEpisode: true),
      onSecondaryTap: () => _open(context, item),
    );
  }
}
