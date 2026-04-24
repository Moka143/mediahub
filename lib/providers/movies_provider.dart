import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/movie.dart';
import 'shows_provider.dart';

/// Search query notifier for movies
class MovieSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';
  
  void set(String value) => state = value;
  void clear() => state = '';
}

/// Search query state for movies
final movieSearchQueryProvider = NotifierProvider<MovieSearchQueryNotifier, String>(
  MovieSearchQueryNotifier.new,
);

/// Movie search results provider
final movieSearchResultsProvider = FutureProvider.autoDispose<List<Movie>>((ref) async {
  final query = ref.watch(movieSearchQueryProvider);
  if (query.isEmpty) return [];

  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.searchMovies(query);
});

/// Popular movies provider
final popularMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getPopularMovies();
});

/// Trending movies provider (weekly)
final trendingMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getTrendingMovies(timeWindow: 'week');
});

/// Top rated movies provider
final topRatedMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getTopRatedMovies();
});

/// Upcoming movies provider
final upcomingMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getUpcomingMovies();
});

/// Now playing movies provider
final nowPlayingMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getNowPlayingMovies();
});

/// Movie details by ID (family provider for caching multiple movies)
final movieDetailsProvider = FutureProvider.family<Movie, int>((ref, movieId) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getMovieDetailsWithImdb(movieId);
});

/// Similar movies provider
final similarMoviesProvider = FutureProvider.family<List<Movie>, int>((ref, movieId) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getSimilarMovies(movieId);
});

/// Recommended movies provider
final recommendedMoviesProvider = FutureProvider.family<List<Movie>, int>((ref, movieId) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getRecommendedMovies(movieId);
});

/// Movie genres provider
final movieGenresProvider = FutureProvider<Map<int, String>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getMovieGenres();
});
