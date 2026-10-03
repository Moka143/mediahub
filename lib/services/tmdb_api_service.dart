import 'package:dio/dio.dart';

import '../models/episode.dart';
import '../models/movie.dart';
import '../models/show.dart';
import '../utils/error_messages.dart';
import 'http_client.dart';

/// Service for interacting with TMDB (The Movie Database) API.
///
/// Auth uses TMDB v4 Bearer tokens (the modern auth scheme). v3 endpoints
/// accept v4 Bearer auth, so we still hit `/3/...` paths — only the auth
/// header differs from the legacy v3 query-param `api_key=…` flow.
///
/// `accessToken` may be either a v4 Read Access Token (app-scoped, bundled
/// at build time or pasted by the user) or a v4 User Access Token (returned
/// by [TmdbAccountService.createAccessToken] after browser sign-in). The
/// effective-token provider picks the user token when signed in, otherwise
/// the read token.
///
/// Every call goes through [_get], which turns a failure into a
/// [TmdbApiException] that keeps the status code — so a caller can tell a
/// rejected token (401) from no network, which used to be one flattened
/// string.
class TmdbApiService {
  static const String _baseUrl = 'https://api.themoviedb.org/3';
  static const String _imageBaseUrl = 'https://image.tmdb.org/t/p';

  final Dio _dio;
  final String accessToken;

  TmdbApiService({required this.accessToken})
    : _dio = buildJsonDio(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

  /// True when a non-empty access token is configured.
  bool get isConfigured => accessToken.isNotEmpty;

  /// Auth is sent in the Authorization header, so only the language is a
  /// default query parameter.
  static const Map<String, dynamic> _defaultParams = {'language': 'en-US'};

  /// GET [path] and hand the decoded body to [parse].
  ///
  /// The one place a request can fail. [what] names the request for the
  /// exception message ("search shows"); transport and HTTP failures keep
  /// their status code and kind, and a response that does not have the
  /// expected shape is reported as such rather than as a `TypeError`.
  Future<T> _get<T>(
    String what,
    String path,
    T Function(Map<String, dynamic> data) parse, {
    Map<String, dynamic> query = const {},
  }) async {
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        path,
        queryParameters: {..._defaultParams, ...query},
      );
    } on DioException catch (e) {
      throw TmdbApiException.fromDio(what, e);
    }
    try {
      return parse(response.data as Map<String, dynamic>);
    } catch (e) {
      throw TmdbApiException('Unexpected TMDB answer to $what: $e');
    }
  }

  static List<Show> _shows(Map<String, dynamic> data) => [
    for (final json in data['results'] as List<dynamic>)
      Show.fromJson(json as Map<String, dynamic>),
  ];

  static List<Movie> _movies(Map<String, dynamic> data) => [
    for (final json in data['results'] as List<dynamic>)
      Movie.fromJson(json as Map<String, dynamic>),
  ];

  /// Search for TV shows by query.
  ///
  /// [firstAirDateYear] narrows the search to shows that premiered that
  /// year. Without it a search for "Doctor Who" cannot tell the 1963 series
  /// from the 2005 one, and anything that writes to TMDB on the strength of
  /// the first hit writes to whichever ranks higher.
  Future<List<Show>> searchShows(
    String query, {
    int page = 1,
    int? firstAirDateYear,
  }) => _get(
    'search shows',
    '/search/tv',
    _shows,
    query: {
      'query': query,
      'page': page,
      'include_adult': false,
      'first_air_date_year': ?firstAirDateYear,
    },
  );

  /// Get popular TV shows
  Future<List<Show>> getPopularShows({int page = 1}) =>
      _get('popular shows', '/tv/popular', _shows, query: {'page': page});

  /// Get trending TV shows (day or week)
  Future<List<Show>> getTrendingShows({
    String timeWindow = 'week',
    int page = 1,
  }) => _get(
    'trending shows',
    '/trending/tv/$timeWindow',
    _shows,
    query: {'page': page},
  );

  /// Get top rated TV shows
  Future<List<Show>> getTopRatedShows({int page = 1}) =>
      _get('top rated shows', '/tv/top_rated', _shows, query: {'page': page});

  /// Get shows currently airing
  Future<List<Show>> getOnTheAirShows({int page = 1}) =>
      _get('on-the-air shows', '/tv/on_the_air', _shows, query: {'page': page});

  /// Get detailed information about a TV show. Note it carries no IMDB id —
  /// see [getShowDetailsWithImdb].
  Future<Show> getShowDetails(int showId) =>
      _get('show details', '/tv/$showId', Show.fromJson);

  /// The show's IMDB id from `/tv/{id}/external_ids`, or null when IMDB has
  /// none. The cheap way to the id when the details are not needed.
  Future<String?> getShowImdbId(int showId) => _get(
    'show external ids',
    '/tv/$showId/external_ids',
    (data) => data['imdb_id'] as String?,
  );

  /// Get show details with external IDs + trailers + cast in one call.
  ///
  /// Uses `append_to_response` to fold four endpoints into a single
  /// request: external_ids (for IMDB), videos (trailers/teasers),
  /// aggregate_credits (show-level cast across all seasons — better
  /// than per-season credits for the details page). The seasons list rides
  /// on the same response, so nothing needs `/tv/{id}` a second time.
  Future<Show> getShowDetailsWithImdb(int showId) => _get(
    'show details',
    '/tv/$showId',
    (data) {
      // Merge imdb_id from external_ids into main data
      final external = data['external_ids'];
      if (external is Map<String, dynamic>) {
        data['imdb_id'] = external['imdb_id'];
      }
      return Show.fromJson(data);
    },
    query: {'append_to_response': 'external_ids,videos,aggregate_credits'},
  );

  /// Get episodes for a specific season
  Future<List<Episode>> getSeasonEpisodes(int showId, int seasonNumber) => _get(
    'season episodes',
    '/tv/$showId/season/$seasonNumber',
    (data) => [
      for (final json in (data['episodes'] as List<dynamic>?) ?? const [])
        Episode.fromJson({...json as Map<String, dynamic>, 'show_id': showId}),
    ],
  );

  /// Get similar shows
  Future<List<Show>> getSimilarShows(int showId, {int page = 1}) => _get(
    'similar shows',
    '/tv/$showId/similar',
    _shows,
    query: {'page': page},
  );

  /// Get recommended shows based on a show
  Future<List<Show>> getRecommendedShows(int showId, {int page = 1}) => _get(
    'recommended shows',
    '/tv/$showId/recommendations',
    _shows,
    query: {'page': page},
  );

  /// Discover shows with filters
  Future<List<Show>> discoverShows({
    int page = 1,
    String? sortBy,
    int? year,
    String? withGenres,
    int? voteCountGte,
  }) => _get(
    'discover shows',
    '/discover/tv',
    _shows,
    query: {
      'page': page,
      'sort_by': ?sortBy,
      'first_air_date_year': ?year,
      'with_genres': ?withGenres,
      'vote_count.gte': ?voteCountGte,
    },
  );

  // Static helper methods for image URLs
  static String getPosterUrl(String? posterPath, {String size = 'w500'}) {
    if (posterPath == null) return '';
    return '$_imageBaseUrl/$size$posterPath';
  }

  // ==================== MOVIE METHODS ====================

  /// Search for movies by query.
  ///
  /// [year] narrows the search to that release year — `Halloween` 1978 and
  /// 2018 are both just "Halloween" to a bare search.
  Future<List<Movie>> searchMovies(String query, {int page = 1, int? year}) =>
      _get(
        'search movies',
        '/search/movie',
        _movies,
        query: {
          'query': query,
          'page': page,
          'include_adult': false,
          'year': ?year,
        },
      );

  /// Get popular movies
  Future<List<Movie>> getPopularMovies({int page = 1}) =>
      _get('popular movies', '/movie/popular', _movies, query: {'page': page});

  /// Get trending movies (day or week)
  Future<List<Movie>> getTrendingMovies({
    String timeWindow = 'week',
    int page = 1,
  }) => _get(
    'trending movies',
    '/trending/movie/$timeWindow',
    _movies,
    query: {'page': page},
  );

  /// Get top rated movies
  Future<List<Movie>> getTopRatedMovies({int page = 1}) => _get(
    'top rated movies',
    '/movie/top_rated',
    _movies,
    query: {'page': page},
  );

  /// Get upcoming movies
  Future<List<Movie>> getUpcomingMovies({int page = 1}) => _get(
    'upcoming movies',
    '/movie/upcoming',
    _movies,
    query: {'page': page},
  );

  /// Get detailed information about a movie
  Future<Movie> getMovieDetails(int movieId) =>
      _get('movie details', '/movie/$movieId', Movie.fromJson);

  /// Get movie details with external IDs + trailers + cast in one call.
  ///
  /// Uses `append_to_response` to fold three endpoints into a single
  /// request: external_ids (for IMDB), videos (trailers/teasers),
  /// credits (top cast).
  Future<Movie> getMovieDetailsWithImdb(int movieId) =>
      _get('movie details', '/movie/$movieId', (data) {
        // Merge imdb_id from external_ids into main data
        final external = data['external_ids'];
        if (external is Map<String, dynamic>) {
          data['imdb_id'] = external['imdb_id'];
        }
        return Movie.fromJson(data);
      }, query: {'append_to_response': 'external_ids,videos,credits'});

  /// Get similar movies
  Future<List<Movie>> getSimilarMovies(int movieId, {int page = 1}) => _get(
    'similar movies',
    '/movie/$movieId/similar',
    _movies,
    query: {'page': page},
  );

  /// Get recommended movies based on a movie
  Future<List<Movie>> getRecommendedMovies(int movieId, {int page = 1}) => _get(
    'recommended movies',
    '/movie/$movieId/recommendations',
    _movies,
    query: {'page': page},
  );

  /// Discover movies with filters
  Future<List<Movie>> discoverMovies({
    int page = 1,
    String? sortBy,
    int? year,
    String? withGenres,
    int? voteCountGte,
  }) => _get(
    'discover movies',
    '/discover/movie',
    _movies,
    query: {
      'page': page,
      'sort_by': ?sortBy,
      'primary_release_year': ?year,
      'with_genres': ?withGenres,
      'vote_count.gte': ?voteCountGte,
    },
  );
}

/// A TMDB request that failed, with enough left of the failure to act on.
///
/// The positional constructor is the one older code used; the named fields
/// are what [classifyFailure] and the screens read to choose between "check
/// your token" and "try again".
class TmdbApiException extends HttpServiceException {
  TmdbApiException(
    super.message, {
    super.statusCode,
    super.isNetwork,
    super.isTimeout,
  });

  /// Build from the [DioException] behind a failed [what] request.
  TmdbApiException.fromDio(String what, DioException e)
    : super.fromDio(
        e.response?.statusCode != null
            ? 'Failed to $what: TMDB answered ${e.response?.statusCode}'
            : 'Failed to $what: ${e.type.name}',
        e,
      );

  @override
  String get kind => 'TmdbApiException';
}
