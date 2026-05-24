import 'package:dio/dio.dart';

/// What TMDB lets a signed-in user mutate from the API.
///
/// **v4 Bearer auth.** Requests use `Authorization: Bearer <accessToken>` —
/// no `api_key` query param, no `session_id`. The token itself identifies
/// the user (for user-scoped operations) or the app (for catalog reads).
///
/// All read/write endpoints stay on the `/3/...` namespace (TMDB accepts
/// v4 Bearer auth on v3 endpoints); only the OAuth flow uses `/4/auth/...`
/// endpoints, which is what gives us the user-scoped access token in the
/// first place.
class TmdbAccountService {
  static const String _baseUrl = 'https://api.themoviedb.org';

  final Dio _dio;
  final String accessToken;

  TmdbAccountService({required this.accessToken})
    : _dio = Dio(
        BaseOptions(
          baseUrl: _baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json;charset=utf-8',
            'Accept': 'application/json',
          },
        ),
      );

  // ============================================================================
  // Authentication (v4 access token flow)
  // ============================================================================

  /// Step 1: ask TMDB for a fresh v4 request token. Valid for ~60 minutes;
  /// user must approve it in their browser before it can be exchanged.
  ///
  /// Uses Bearer = the app's read access token (the currently configured
  /// token on this service instance).
  Future<String> createRequestToken() async {
    try {
      final r = await _dio.post('/4/auth/request_token');
      final token = r.data['request_token'] as String?;
      if (token == null) {
        throw const TmdbAccountException('TMDB did not return a request_token');
      }
      return token;
    } on DioException catch (e) {
      throw TmdbAccountException(
        e.response?.data is Map
            ? (e.response!.data['status_message']?.toString() ??
                  'Failed to create request token')
            : 'Failed to create request token: ${e.message}',
      );
    }
  }

  /// URL the user opens in their browser to approve the request token.
  String authorizeUrl(String requestToken) =>
      'https://www.themoviedb.org/auth/access?request_token=$requestToken';

  /// Step 3: exchange an approved request token for a v4 user access token.
  /// Throws [TmdbAccountException] if the user hasn't approved it yet (401).
  ///
  /// Note: TMDB v4's `/4/auth/access_token` response also includes an
  /// `account_id`, but in **v4 ObjectId string form** (e.g.
  /// `62b8f06b41d54e007e95dd1f`). That's useless for our v3 endpoints —
  /// `/3/account/{id}/favorite` etc need the v3 **integer** account id.
  /// So we drop the v4 account_id here and let the caller fetch the v3
  /// integer one from `/3/account` after we have the bearer token.
  Future<String> createAccessToken(String approvedRequestToken) async {
    try {
      final r = await _dio.post(
        '/4/auth/access_token',
        data: {'request_token': approvedRequestToken},
      );
      final token = r.data['access_token'] as String?;
      if (token == null || token.isEmpty) {
        throw const TmdbAccountException('TMDB did not return an access_token');
      }
      return token;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const TmdbAccountException(
          'Token not yet approved — confirm in the browser, then try again.',
        );
      }
      throw TmdbAccountException(
        e.response?.data is Map
            ? (e.response!.data['status_message']?.toString() ??
                  'Failed to create access token')
            : 'Failed to create access token: ${e.message}',
      );
    }
  }

  /// Revoke a v4 user access token on the TMDB side. Best-effort: returns
  /// false on failure rather than throwing (we still drop it locally).
  ///
  /// The Dio instance must be configured with this same `accessToken` as
  /// its Bearer for the call to succeed.
  Future<bool> deleteAccessToken(String token) async {
    try {
      final r = await _dio.delete(
        '/4/auth/access_token',
        data: {'access_token': token},
      );
      return r.data['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the signed-in user's account: numeric `id` (v3 integer,
  /// needed for `/3/account/{id}/...` mutation paths), `username`, etc.
  ///
  /// Bearer auth identifies the user — calling `/3/account` without a
  /// path id is the documented way to get the *current* user's info.
  Future<TmdbAccount> getAccount() async {
    final r = await _dio.get('/3/account');
    return TmdbAccount.fromJson(r.data as Map<String, dynamic>);
  }

  // ============================================================================
  // Favorites & watchlist mutations
  // ============================================================================

  /// Mark or unmark a TV show or movie as favorite for [accountId].
  Future<void> setFavorite({
    required int accountId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool favorite,
  }) async {
    await _dio.post(
      '/3/account/$accountId/favorite',
      data: {
        'media_type': mediaType.api,
        'media_id': mediaId,
        'favorite': favorite,
      },
    );
  }

  /// Add or remove a TV show or movie from the watchlist for [accountId].
  Future<void> setWatchlist({
    required int accountId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool watchlist,
  }) async {
    await _dio.post(
      '/3/account/$accountId/watchlist',
      data: {
        'media_type': mediaType.api,
        'media_id': mediaId,
        'watchlist': watchlist,
      },
    );
  }

  // ============================================================================
  // Ratings (used as "watched" proxy)
  // ============================================================================
  //
  // TMDB has no native "mark watched" endpoint at any level. Ratings are the
  // only per-item state we can persist server-side for individual episodes,
  // so we use them as a stand-in: rate=10 ↔ watched, DELETE rating ↔ unwatched.
  // See lib/services/library_actions.dart for the wiring.

  /// Default value posted for "mark watched". 10 is the max and the strongest
  /// "I've seen this" signal; users can manually re-rate from TMDB.
  static const double watchedRatingValue = 10.0;

  Future<void> rateMovie({required int movieId, required double value}) =>
      _putRating('/3/movie/$movieId/rating', value);

  Future<void> deleteMovieRating({required int movieId}) =>
      _deleteRating('/3/movie/$movieId/rating');

  Future<void> rateShow({required int seriesId, required double value}) =>
      _putRating('/3/tv/$seriesId/rating', value);

  Future<void> deleteShowRating({required int seriesId}) =>
      _deleteRating('/3/tv/$seriesId/rating');

  Future<void> rateEpisode({
    required int seriesId,
    required int seasonNumber,
    required int episodeNumber,
    required double value,
  }) => _putRating(
    '/3/tv/$seriesId/season/$seasonNumber/episode/$episodeNumber/rating',
    value,
  );

  Future<void> deleteEpisodeRating({
    required int seriesId,
    required int seasonNumber,
    required int episodeNumber,
  }) => _deleteRating(
    '/3/tv/$seriesId/season/$seasonNumber/episode/$episodeNumber/rating',
  );

  Future<void> _putRating(String path, double value) async {
    await _dio.post(path, data: {'value': value});
  }

  Future<void> _deleteRating(String path) async {
    await _dio.delete(path);
  }

  // ============================================================================
  // Account list reads (for sync)
  // ============================================================================

  /// Returns every favorited TV id across all pages.
  Future<Set<int>> getFavoriteShowIds({required int accountId}) =>
      _collectAllPages('/3/account/$accountId/favorite/tv');

  /// Returns every favorited movie id across all pages.
  Future<Set<int>> getFavoriteMovieIds({required int accountId}) =>
      _collectAllPages('/3/account/$accountId/favorite/movies');

  Future<Set<int>> getWatchlistShowIds({required int accountId}) =>
      _collectAllPages('/3/account/$accountId/watchlist/tv');

  Future<Set<int>> getWatchlistMovieIds({required int accountId}) =>
      _collectAllPages('/3/account/$accountId/watchlist/movies');

  /// Returns every rated movie id across all pages — used to reconcile local
  /// "watched" state from TMDB.
  Future<Set<int>> getRatedMovieIds({required int accountId}) =>
      _collectAllPages('/3/account/$accountId/rated/movies');

  /// Returns every rated TV show id across all pages.
  Future<Set<int>> getRatedShowIds({required int accountId}) =>
      _collectAllPages('/3/account/$accountId/rated/tv');

  /// Returns every rated TV episode as (showId, season, episode) tuples across
  /// all pages. Used to mark local files watched from server state on refresh.
  Future<List<TmdbRatedEpisode>> getRatedEpisodes({
    required int accountId,
  }) async {
    final episodes = <TmdbRatedEpisode>[];
    var page = 1;
    while (true) {
      final r = await _dio.get(
        '/3/account/$accountId/rated/tv/episodes',
        queryParameters: {'page': page},
      );
      final results = (r.data['results'] as List<dynamic>?) ?? const [];
      for (final item in results) {
        final m = item as Map<String, dynamic>;
        final showId = m['show_id'];
        final season = m['season_number'];
        final episode = m['episode_number'];
        if (showId is int && season is int && episode is int) {
          episodes.add(
            TmdbRatedEpisode(
              showId: showId,
              seasonNumber: season,
              episodeNumber: episode,
            ),
          );
        }
      }
      final totalPages = r.data['total_pages'] as int? ?? page;
      if (page >= totalPages) break;
      page++;
    }
    return episodes;
  }

  /// Per-item check used when opening a details screen so the heart/bookmark
  /// state reflects the *current* server truth, not a stale local cache.
  Future<TmdbAccountStates> getAccountStates({
    required TmdbMediaType mediaType,
    required int mediaId,
  }) async {
    final r = await _dio.get('/3/${mediaType.api}/$mediaId/account_states');
    return TmdbAccountStates.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Set<int>> _collectAllPages(String path) async {
    final ids = <int>{};
    int page = 1;
    while (true) {
      final r = await _dio.get(path, queryParameters: {'page': page});
      final results = (r.data['results'] as List<dynamic>?) ?? const [];
      for (final item in results) {
        final id = (item as Map<String, dynamic>)['id'];
        if (id is int) ids.add(id);
      }
      final totalPages = r.data['total_pages'] as int? ?? page;
      if (page >= totalPages) break;
      page++;
    }
    return ids;
  }
}

enum TmdbMediaType {
  tv('tv'),
  movie('movie');

  final String api;
  const TmdbMediaType(this.api);
}

class TmdbAccount {
  TmdbAccount({required this.id, required this.username, this.name});

  final int id;
  final String username;
  final String? name;

  factory TmdbAccount.fromJson(Map<String, dynamic> json) {
    return TmdbAccount(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'name': name,
  };
}

class TmdbAccountStates {
  TmdbAccountStates({
    required this.favorite,
    required this.watchlist,
    this.rating,
  });

  final bool favorite;
  final bool watchlist;
  final double? rating;

  factory TmdbAccountStates.fromJson(Map<String, dynamic> json) {
    final rated = json['rated'];
    double? rating;
    if (rated is Map && rated['value'] is num) {
      rating = (rated['value'] as num).toDouble();
    }
    return TmdbAccountStates(
      favorite: json['favorite'] as bool? ?? false,
      watchlist: json['watchlist'] as bool? ?? false,
      rating: rating,
    );
  }
}

class TmdbRatedEpisode {
  const TmdbRatedEpisode({
    required this.showId,
    required this.seasonNumber,
    required this.episodeNumber,
  });

  final int showId;
  final int seasonNumber;
  final int episodeNumber;
}

class TmdbAccountException implements Exception {
  const TmdbAccountException(this.message);
  final String message;
  @override
  String toString() => 'TmdbAccountException: $message';
}
