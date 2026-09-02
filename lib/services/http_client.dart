import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'app_logger.dart';

/// One place to build the JSON HTTP clients the metadata and indexer services
/// use.
///
/// Five services each hand-rolled `Dio(BaseOptions(...))`, which is how they
/// ended up with four different timeout pairs for no stated reason. Timeouts
/// stay per-caller here — they are a real characteristic of each upstream
/// (EZTV is slow to connect, TMDB is not) and quietly unifying them would
/// change failure rates. What is shared is the shape, the `Accept` header,
/// and the retry policy in [RetryInterceptor].
///
/// qBittorrent's client is deliberately not built here: it needs its own
/// interceptor, cookie handling and a `validateStatus` that lets 4xx through.
Dio buildJsonDio({
  required String baseUrl,
  required Duration connectTimeout,
  required Duration receiveTimeout,
  Map<String, String> headers = const {},
  int maxRetries = RetryInterceptor.defaultMaxRetries,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: {'Accept': 'application/json', ...headers},
    ),
  );
  if (maxRetries > 0) {
    dio.interceptors.add(RetryInterceptor(dio: dio, maxRetries: maxRetries));
  }
  return dio;
}

/// Retries a failed **idempotent** request a bounded number of times with
/// exponential backoff.
///
/// Every one of these upstreams is a public API reached over a home
/// connection, and a single dropped TCP handshake currently surfaces as a
/// missing poster, an empty favourites list, or a "no torrents found" that
/// the user reads as a real answer. One retry turns most of those back into
/// a slightly slower success.
///
/// The policy is deliberately narrow, because a retry is only ever safe when
/// repeating the request cannot change server state and cannot make the
/// user's situation worse:
///
///  * **GET and HEAD only.** A retried POST could double-rate an episode or
///    double-add a torrent. [TmdbAccountService]'s writes go through this
///    same client, so this restriction is load-bearing, not theoretical.
///  * **Transport failures and 5xx / 429 only.** A 4xx is the server saying
///    the request itself is wrong — a bad API key answers identically to the
///    third attempt as to the first, so retrying only delays the error the
///    user needs to see.
///  * **Never a cancellation.** A cancelled request is one the app itself
///    abandoned (the user left the screen, a newer search superseded this
///    one). Reviving it would resurrect exactly the work that was called off.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required Dio dio,
    this.maxRetries = defaultMaxRetries,
    this.baseDelay = const Duration(milliseconds: 300),
  }) : _dio = dio;

  static const int defaultMaxRetries = 2;

  final Dio _dio;

  /// Attempts *after* the first. Two retries means at most three requests.
  final int maxRetries;

  /// Delay before the first retry; doubled for each subsequent one.
  final Duration baseDelay;

  /// Header the interceptor uses to count attempts on a request it re-issues.
  /// Lives in `extra`, so it is never sent over the wire.
  static const String _attemptKey = 'mediahub_retry_attempt';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final attempt = (err.requestOptions.extra[_attemptKey] as int?) ?? 0;

    if (attempt >= maxRetries || !_isRetryable(err)) {
      handler.next(err);
      return;
    }

    // 300ms, 600ms, 1.2s… — enough to outlast a blip without making a real
    // outage feel like a hang.
    final delay = baseDelay * math.pow(2, attempt).toDouble();
    await Future<void>.delayed(delay);

    final options = err.requestOptions..extra[_attemptKey] = attempt + 1;

    AppLog.d(
      '[Http] retry ${attempt + 1}/$maxRetries ${options.method} '
      '${options.path}: ${err.type.name}',
    );

    try {
      handler.resolve(await _dio.fetch<dynamic>(options));
    } on DioException catch (e) {
      // The retry failed too. Hand the *new* error on so the interceptor
      // chain sees the latest attempt rather than a stale one.
      handler.next(e);
    }
  }

  /// Whether repeating [err]'s request is both safe and plausibly useful.
  static bool _isRetryable(DioException err) {
    final method = err.requestOptions.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD') return false;

    switch (err.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final status = err.response?.statusCode ?? 0;
        // 429 is an explicit "come back shortly"; 5xx is the server failing
        // at something it may well succeed at next time.
        return status == 429 || status >= 500;
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        // `transformTimeout` is our own decoding being slow, not the
        // network's — re-fetching the same payload would just be slow again.
        return false;
    }
  }
}
