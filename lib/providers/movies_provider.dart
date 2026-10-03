import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/movie.dart';
import 'shows_provider.dart';

/// Search query notifier for movies
class MovieSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

/// Search query state for movies
final movieSearchQueryProvider =
    NotifierProvider<MovieSearchQueryNotifier, String>(
      MovieSearchQueryNotifier.new,
    );

/// Movie search results provider
final movieSearchResultsProvider = FutureProvider.autoDispose<List<Movie>>((
  ref,
) async {
  final query = ref.watch(movieSearchQueryProvider);
  if (query.isEmpty) return [];

  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.searchMovies(query);
});

/// Trending movies provider (weekly)
final trendingMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.getTrendingMovies(timeWindow: 'week');
});

/// Movie details by ID (family provider for caching multiple movies)
final movieDetailsProvider = FutureProvider.family<Movie, int>((
  ref,
  movieId,
) async {
  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.getMovieDetailsWithImdb(movieId);
});

/// Similar movies provider
final similarMoviesProvider = FutureProvider.family<List<Movie>, int>((
  ref,
  movieId,
) async {
  final tmdbService = ref.watch(tmdbApiServiceProvider);
  return tmdbService.getSimilarMovies(movieId);
});
