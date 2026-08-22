import 'package:dio/dio.dart';

/// One place to build the JSON HTTP clients the metadata and indexer services
/// use.
///
/// Five services each hand-rolled `Dio(BaseOptions(...))`, which is how they
/// ended up with four different timeout pairs for no stated reason. Timeouts
/// stay per-caller here — they are a real characteristic of each upstream
/// (EZTV is slow to connect, TMDB is not) and quietly unifying them would
/// change failure rates. What is shared is the shape and the `Accept` header.
///
/// qBittorrent's client is deliberately not built here: it needs its own
/// interceptor, cookie handling and a `validateStatus` that lets 4xx through.
Dio buildJsonDio({
  required String baseUrl,
  required Duration connectTimeout,
  required Duration receiveTimeout,
  Map<String, String> headers = const {},
}) {
  return Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: {'Accept': 'application/json', ...headers},
    ),
  );
}
