import 'package:dio/dio.dart';

/// What TMDB lets a signed-in user mutate from the API.
///
/// All mutation endpoints round-trip in this service so the caller can
/// optimistically update local state and reconcile with the server's response.
class TmdbAccountService {
  static const String _baseUrl = 'https://api.themoviedb.org/3';

  final Dio _dio;
  final String apiKey;

  TmdbAccountService({required this.apiKey})
    : _dio = Dio(
        BaseOptions(
          baseUrl: _baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          headers: {'content-type': 'application/json'},
        ),
      );

  Map<String, dynamic> get _key => {'api_key': apiKey};

  // ============================================================================
  // Authentication (v3 session flow)
  // ============================================================================

  /// Step 1: ask TMDB for a fresh request token. Valid for ~60 minutes; user
  /// must approve it in their browser before it can be exchanged.
  Future<String> createRequestToken() async {
    final r = await _dio.get(
      '/authentication/token/new',
      queryParameters: _key,
    );
    final token = r.data['request_token'] as String?;
    if (token == null) {
      throw const TmdbAccountException('TMDB did not return a request_token');
    }
    return token;
  }

  /// URL the user opens in their browser to approve the request token.
  /// On TMDB's confirmation page they accept, then can close the tab.
  String authorizeUrl(String requestToken) =>
      'https://www.themoviedb.org/authenticate/$requestToken';

  /// Step 3: exchange an approved request token for a session_id. Throws
  /// [TmdbAccountException] if the user hasn't approved it yet.
  Future<String> createSession(String approvedRequestToken) async {
    try {
      final r = await _dio.post(
        '/authentication/session/new',
        queryParameters: _key,
        data: {'request_token': approvedRequestToken},
      );
      final id = r.data['session_id'] as String?;
      if (id == null) {
        throw const TmdbAccountException('TMDB did not return a session_id');
      }
      return id;
    } on DioException catch (e) {
      // 401 = token not yet authorized. Surface a friendlier message.
      if (e.response?.statusCode == 401) {
        throw const TmdbAccountException(
          'Token not yet approved — confirm in the browser, then try again.',
        );
      }
      rethrow;
    }
  }

  /// Revoke a session on the TMDB side. Best-effort: returns false on
  /// failure rather than throwing (we still drop it locally either way).
  Future<bool> deleteSession(String sessionId) async {
    try {
      final r = await _dio.delete(
        '/authentication/session',
        queryParameters: _key,
        data: {'session_id': sessionId},
      );
      return r.data['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Returns the user's account: numeric `id` (used in mutation paths),
  /// `username`, etc.
  Future<TmdbAccount> getAccount(String sessionId) async {
    final r = await _dio.get(
      '/account',
      queryParameters: {..._key, 'session_id': sessionId},
    );
    return TmdbAccount.fromJson(r.data as Map<String, dynamic>);
  }

  // ============================================================================
  // Favorites & watchlist mutations
  // ============================================================================

  /// Mark or unmark a TV show or movie as favorite for [accountId].
  Future<void> setFavorite({
    required int accountId,
    required String sessionId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool favorite,
  }) async {
    await _dio.post(
      '/account/$accountId/favorite',
      queryParameters: {..._key, 'session_id': sessionId},
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
    required String sessionId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool watchlist,
  }) async {
    await _dio.post(
      '/account/$accountId/watchlist',
      queryParameters: {..._key, 'session_id': sessionId},
      data: {
        'media_type': mediaType.api,
        'media_id': mediaId,
        'watchlist': watchlist,
      },
    );
  }

  // ============================================================================
  // Account list reads (for sync)
  // ============================================================================

  /// Returns every favorited TV id across all pages.
  Future<Set<int>> getFavoriteShowIds({
    required int accountId,
    required String sessionId,
  }) =>
      _collectAllPages('/account/$accountId/favorite/tv', sessionId: sessionId);

  /// Returns every favorited movie id across all pages.
  Future<Set<int>> getFavoriteMovieIds({
    required int accountId,
    required String sessionId,
  }) => _collectAllPages(
    '/account/$accountId/favorite/movies',
    sessionId: sessionId,
  );

  Future<Set<int>> getWatchlistShowIds({
    required int accountId,
    required String sessionId,
  }) => _collectAllPages(
    '/account/$accountId/watchlist/tv',
    sessionId: sessionId,
  );

  Future<Set<int>> getWatchlistMovieIds({
    required int accountId,
    required String sessionId,
  }) => _collectAllPages(
    '/account/$accountId/watchlist/movies',
    sessionId: sessionId,
  );

  /// Per-item check used when opening a details screen so the heart/bookmark
  /// state reflects the *current* server truth, not a stale local cache.
  Future<TmdbAccountStates> getAccountStates({
    required TmdbMediaType mediaType,
    required int mediaId,
    required String sessionId,
  }) async {
    final r = await _dio.get(
      '/${mediaType.api}/$mediaId/account_states',
      queryParameters: {..._key, 'session_id': sessionId},
    );
    return TmdbAccountStates.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Set<int>> _collectAllPages(
    String path, {
    required String sessionId,
  }) async {
    final ids = <int>{};
    int page = 1;
    while (true) {
      final r = await _dio.get(
        path,
        queryParameters: {..._key, 'session_id': sessionId, 'page': page},
      );
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

class TmdbAccountException implements Exception {
  const TmdbAccountException(this.message);
  final String message;
  @override
  String toString() => 'TmdbAccountException: $message';
}
