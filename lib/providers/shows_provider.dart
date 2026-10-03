import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/episode.dart';
import '../models/show.dart';
import '../services/tmdb_api_service.dart';
import '../services/tmdb_title_resolver.dart';
import 'tmdb_account_provider.dart';

/// Provider for TMDB API service — uses the effective Bearer token (user
/// access token when signed in, otherwise the bundled / user-pasted read
/// token). Rebuilt whenever the token source changes, and everything below
/// watches it, so a new token reaches every request.
final tmdbApiServiceProvider = Provider<TmdbApiService>((ref) {
  return TmdbApiService(accessToken: ref.watch(tmdbBearerTokenProvider));
});

/// Title → TMDB id resolution, with its caches. Rebuilt with the TMDB
/// service — on sign-in, sign-out and token change — which is what keeps a
/// cache from outliving the session it was filled in.
final tmdbTitleResolverProvider = Provider<TmdbTitleResolver>((ref) {
  return TmdbTitleResolver(ref.watch(tmdbApiServiceProvider));
});

/// Search query notifier
class ShowSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

/// Search query state
final showSearchQueryProvider =
    NotifierProvider<ShowSearchQueryNotifier, String>(
      ShowSearchQueryNotifier.new,
    );

/// Search results provider
final showSearchResultsProvider = FutureProvider.autoDispose<List<Show>>((
  ref,
) async {
  final query = ref.watch(showSearchQueryProvider);
  if (query.isEmpty) return [];

  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.searchShows(query);
});

/// Trending shows provider (weekly)
final trendingShowsProvider = FutureProvider<List<Show>>((ref) async {
  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.getTrendingShows(timeWindow: 'week');
});

/// Show details by ID (family provider for caching multiple shows), with the
/// IMDB id, trailers, cast and seasons — see
/// [TmdbApiService.getShowDetailsWithImdb]. The seasons ride on the same
/// response ([Show.seasons]); nothing needs `/tv/{id}` a second time.
final showDetailsProvider = FutureProvider.family<Show, int>((
  ref,
  showId,
) async {
  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.getShowDetailsWithImdb(showId);
});

/// Episodes for a specific season
final seasonEpisodesProvider =
    FutureProvider.family<List<Episode>, ({int showId, int seasonNumber})>((
      ref,
      params,
    ) async {
      final tmdbService = ref.watch(tmdbApiServiceProvider);
      return tmdbService.getSeasonEpisodes(params.showId, params.seasonNumber);
    });

/// Similar shows provider
final similarShowsProvider = FutureProvider.family<List<Show>, int>((
  ref,
  showId,
) async {
  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.getSimilarShows(showId);
});
