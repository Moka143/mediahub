import 'package:dio/dio.dart';
import '../models/movie.dart';
import '../models/show.dart';
import '../models/season.dart';
import '../models/episode.dart';

/// Service for interacting with TMDB (The Movie Database) API
///
/// API keys are provided by the user via onboarding / settings — we do not
/// ship a shared key in source. Get one free at
/// https://www.themoviedb.org/settings/api
class TmdbApiService {
  static const String _baseUrl = 'https://api.themoviedb.org/3';
  static const String _imageBaseUrl = 'https://image.tmdb.org/t/p';

  final Dio _dio;
  final String apiKey;

  TmdbApiService({required this.apiKey})
    : _dio = Dio(
        BaseOptions(
          baseUrl: _baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );

  /// True when a non-empty API key is configured.
  bool get isConfigured => apiKey.isNotEmpty;

  /// Get common query parameters
  Map<String, dynamic> get _defaultParams => {
    'api_key': apiKey,
    'language': 'en-US',
  };

  /// Search for TV shows by query
  Future<List<Show>> searchShows(String query, {int page = 1}) async {
    try {
      final response = await _dio.get(
        '/search/tv',
        queryParameters: {
          ..._defaultParams,
          'query': query,
          'page': page,
          'include_adult': false,
        },
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to search shows: $e');
    }
  }

  /// Get popular TV shows
  Future<List<Show>> getPopularShows({int page = 1}) async {
    try {
      final response = await _dio.get(
        '/tv/popular',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get popular shows: $e');
    }
  }

  /// Get trending TV shows (day or week)
  Future<List<Show>> getTrendingShows({
    String timeWindow = 'week',
    int page = 1,
  }) async {
    try {
      final response = await _dio.get(
        '/trending/tv/$timeWindow',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get trending shows: $e');
    }
  }

  /// Get top rated TV shows
  Future<List<Show>> getTopRatedShows({int page = 1}) async {
    try {
      final response = await _dio.get(
        '/tv/top_rated',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get top rated shows: $e');
    }
  }

  /// Get shows currently airing
  Future<List<Show>> getOnTheAirShows({int page = 1}) async {
    try {
      final response = await _dio.get(
        '/tv/on_the_air',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get on-the-air shows: $e');
    }
  }

  /// Get detailed information about a TV show
  Future<Show> getShowDetails(int showId) async {
    try {
      final response = await _dio.get(
        '/tv/$showId',
        queryParameters: _defaultParams,
      );

      return Show.fromJson(response.data);
    } catch (e) {
      throw TmdbApiException('Failed to get show details: $e');
    }
  }

  /// Get external IDs for a show (including IMDB ID)
  Future<String?> getShowImdbId(int showId) async {
    try {
      final response = await _dio.get(
        '/tv/$showId/external_ids',
        queryParameters: _defaultParams,
      );

      return response.data['imdb_id'] as String?;
    } catch (e) {
      throw TmdbApiException('Failed to get external IDs: $e');
    }
  }

  /// Get show details with external IDs in one call
  Future<Show> getShowDetailsWithImdb(int showId) async {
    try {
      final response = await _dio.get(
        '/tv/$showId',
        queryParameters: {
          ..._defaultParams,
          'append_to_response': 'external_ids',
        },
      );

      final data = response.data;
      // Merge imdb_id from external_ids into main data
      if (data['external_ids'] != null) {
        data['imdb_id'] = data['external_ids']['imdb_id'];
      }

      return Show.fromJson(data);
    } catch (e) {
      throw TmdbApiException('Failed to get show details with IMDB: $e');
    }
  }

  /// Get all seasons for a TV show
  Future<List<Season>> getShowSeasons(int showId) async {
    try {
      final response = await _dio.get(
        '/tv/$showId',
        queryParameters: _defaultParams,
      );

      final seasons = response.data['seasons'] as List<dynamic>?;
      if (seasons == null) return [];

      return seasons.map((json) => Season.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get show seasons: $e');
    }
  }

  /// Get episodes for a specific season
  Future<List<Episode>> getSeasonEpisodes(int showId, int seasonNumber) async {
    try {
      final response = await _dio.get(
        '/tv/$showId/season/$seasonNumber',
        queryParameters: _defaultParams,
      );

      final episodes = response.data['episodes'] as List<dynamic>?;
      if (episodes == null) return [];

      return episodes
          .map((json) => Episode.fromJson({...json, 'show_id': showId}))
          .toList();
    } catch (e) {
      throw TmdbApiException('Failed to get season episodes: $e');
    }
  }

  /// Get a specific episode's details
  Future<Episode> getEpisodeDetails(
    int showId,
    int seasonNumber,
    int episodeNumber,
  ) async {
    try {
      final response = await _dio.get(
        '/tv/$showId/season/$seasonNumber/episode/$episodeNumber',
        queryParameters: _defaultParams,
      );

      return Episode.fromJson({...response.data, 'show_id': showId});
    } catch (e) {
      throw TmdbApiException('Failed to get episode details: $e');
    }
  }

  /// Get similar shows
  Future<List<Show>> getSimilarShows(int showId, {int page = 1}) async {
    try {
      final response = await _dio.get(
        '/tv/$showId/similar',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get similar shows: $e');
    }
  }

  /// Get recommended shows based on a show
  Future<List<Show>> getRecommendedShows(int showId, {int page = 1}) async {
    try {
      final response = await _dio.get(
        '/tv/$showId/recommendations',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get recommended shows: $e');
    }
  }

  /// Discover shows with filters
  Future<List<Show>> discoverShows({
    int page = 1,
    String? sortBy,
    int? year,
    String? withGenres,
    double? voteAverageGte,
  }) async {
    try {
      final params = {
        ..._defaultParams,
        'page': page,
        if (sortBy != null) 'sort_by': sortBy,
        if (year != null) 'first_air_date_year': year,
        if (withGenres != null) 'with_genres': withGenres,
        if (voteAverageGte != null) 'vote_average.gte': voteAverageGte,
      };

      final response = await _dio.get('/discover/tv', queryParameters: params);

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Show.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to discover shows: $e');
    }
  }

  /// Get TV genre list
  Future<Map<int, String>> getGenres() async {
    try {
      final response = await _dio.get(
        '/genre/tv/list',
        queryParameters: _defaultParams,
      );

      final genres = response.data['genres'] as List<dynamic>;
      return {for (var g in genres) g['id'] as int: g['name'] as String};
    } catch (e) {
      throw TmdbApiException('Failed to get genres: $e');
    }
  }

  // Static helper methods for image URLs
  static String getPosterUrl(String? posterPath, {String size = 'w500'}) {
    if (posterPath == null) return '';
    return '$_imageBaseUrl/$size$posterPath';
  }

  static String getBackdropUrl(
    String? backdropPath, {
    String size = 'original',
  }) {
    if (backdropPath == null) return '';
    return '$_imageBaseUrl/$size$backdropPath';
  }

  static String getStillUrl(String? stillPath, {String size = 'w300'}) {
    if (stillPath == null) return '';
    return '$_imageBaseUrl/$size$stillPath';
  }

  // ==================== MOVIE METHODS ====================

  /// Search for movies by query
  Future<List<Movie>> searchMovies(String query, {int page = 1}) async {
    try {
      final response = await _dio.get(
        '/search/movie',
        queryParameters: {
          ..._defaultParams,
          'query': query,
          'page': page,
          'include_adult': false,
        },
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to search movies: $e');
    }
  }

  /// Get popular movies
  Future<List<Movie>> getPopularMovies({int page = 1}) async {
    try {
      final response = await _dio.get(
        '/movie/popular',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get popular movies: $e');
    }
  }

  /// Get trending movies (day or week)
  Future<List<Movie>> getTrendingMovies({
    String timeWindow = 'week',
    int page = 1,
  }) async {
    try {
      final response = await _dio.get(
        '/trending/movie/$timeWindow',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get trending movies: $e');
    }
  }

  /// Get top rated movies
  Future<List<Movie>> getTopRatedMovies({int page = 1}) async {
    try {
      final response = await _dio.get(
        '/movie/top_rated',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get top rated movies: $e');
    }
  }

  /// Get upcoming movies
  Future<List<Movie>> getUpcomingMovies({int page = 1}) async {
    try {
      final response = await _dio.get(
        '/movie/upcoming',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get upcoming movies: $e');
    }
  }

  /// Get now playing movies
  Future<List<Movie>> getNowPlayingMovies({int page = 1}) async {
    try {
      final response = await _dio.get(
        '/movie/now_playing',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get now playing movies: $e');
    }
  }

  /// Get detailed information about a movie
  Future<Movie> getMovieDetails(int movieId) async {
    try {
      final response = await _dio.get(
        '/movie/$movieId',
        queryParameters: _defaultParams,
      );

      return Movie.fromJson(response.data);
    } catch (e) {
      throw TmdbApiException('Failed to get movie details: $e');
    }
  }

  /// Get movie details with external IDs in one call
  Future<Movie> getMovieDetailsWithImdb(int movieId) async {
    try {
      final response = await _dio.get(
        '/movie/$movieId',
        queryParameters: {
          ..._defaultParams,
          'append_to_response': 'external_ids',
        },
      );

      final data = response.data;
      // Merge imdb_id from external_ids into main data
      if (data['external_ids'] != null) {
        data['imdb_id'] = data['external_ids']['imdb_id'];
      }

      return Movie.fromJson(data);
    } catch (e) {
      throw TmdbApiException('Failed to get movie details with IMDB: $e');
    }
  }

  /// Get external IDs for a movie (including IMDB ID)
  Future<String?> getMovieImdbId(int movieId) async {
    try {
      final response = await _dio.get(
        '/movie/$movieId/external_ids',
        queryParameters: _defaultParams,
      );

      return response.data['imdb_id'] as String?;
    } catch (e) {
      throw TmdbApiException('Failed to get movie external IDs: $e');
    }
  }

  /// Get similar movies
  Future<List<Movie>> getSimilarMovies(int movieId, {int page = 1}) async {
    try {
      final response = await _dio.get(
        '/movie/$movieId/similar',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get similar movies: $e');
    }
  }

  /// Get recommended movies based on a movie
  Future<List<Movie>> getRecommendedMovies(int movieId, {int page = 1}) async {
    try {
      final response = await _dio.get(
        '/movie/$movieId/recommendations',
        queryParameters: {..._defaultParams, 'page': page},
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to get recommended movies: $e');
    }
  }

  /// Discover movies with filters
  Future<List<Movie>> discoverMovies({
    int page = 1,
    String? sortBy,
    int? year,
    String? withGenres,
    double? voteAverageGte,
    int? runtimeGte,
    int? runtimeLte,
  }) async {
    try {
      final params = {
        ..._defaultParams,
        'page': page,
        if (sortBy != null) 'sort_by': sortBy,
        if (year != null) 'primary_release_year': year,
        if (withGenres != null) 'with_genres': withGenres,
        if (voteAverageGte != null) 'vote_average.gte': voteAverageGte,
        if (runtimeGte != null) 'with_runtime.gte': runtimeGte,
        if (runtimeLte != null) 'with_runtime.lte': runtimeLte,
      };

      final response = await _dio.get(
        '/discover/movie',
        queryParameters: params,
      );

      final results = response.data['results'] as List<dynamic>;
      return results.map((json) => Movie.fromJson(json)).toList();
    } catch (e) {
      throw TmdbApiException('Failed to discover movies: $e');
    }
  }

  /// Get movie genre list
  Future<Map<int, String>> getMovieGenres() async {
    try {
      final response = await _dio.get(
        '/genre/movie/list',
        queryParameters: _defaultParams,
      );

      final genres = response.data['genres'] as List<dynamic>;
      return {for (var g in genres) g['id'] as int: g['name'] as String};
    } catch (e) {
      throw TmdbApiException('Failed to get movie genres: $e');
    }
  }
}

/// Exception for TMDB API errors
class TmdbApiException implements Exception {
  final String message;
  TmdbApiException(this.message);

  @override
  String toString() => 'TmdbApiException: $message';
}
