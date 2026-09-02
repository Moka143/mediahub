import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/http_client.dart';

/// [RetryInterceptor] is the only place in the app that will re-send a
/// request the user did not ask for twice, so its policy is pinned here in
/// both directions: what it must retry, and — more importantly — what it must
/// never retry.
///
/// A fake [HttpClientAdapter] stands in for the network, so these run with no
/// sockets and no waiting beyond the interceptor's own backoff.
void main() {
  /// Builds a client whose adapter replays [responses] in order, recording
  /// how many requests actually went out.
  ({Dio dio, List<RequestOptions> sent}) client(
    List<Object> responses, {
    int maxRetries = 2,
  }) {
    final sent = <RequestOptions>[];
    final dio = buildJsonDio(
      baseUrl: 'https://example.test',
      connectTimeout: const Duration(seconds: 1),
      receiveTimeout: const Duration(seconds: 1),
      maxRetries: maxRetries,
    );
    dio.httpClientAdapter = _ScriptedAdapter(responses, sent);
    return (dio: dio, sent: sent);
  }

  /// A transport-level failure, the kind a dropped connection produces.
  DioException connectionError(RequestOptions o) => DioException(
    requestOptions: o,
    type: DioExceptionType.connectionError,
    error: 'no route to host',
  );

  DioException status(RequestOptions o, int code) => DioException(
    requestOptions: o,
    type: DioExceptionType.badResponse,
    response: Response<dynamic>(requestOptions: o, statusCode: code),
  );

  ResponseBody ok([String body = '{"ok":true}']) => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  group('retries', () {
    test('a dropped connection is retried and can succeed', () async {
      final c = client([connectionError, ok()]);

      final res = await c.dio.get<dynamic>('/thing');

      expect(res.statusCode, 200);
      expect(c.sent, hasLength(2));
    });

    test('gives up after maxRetries and reports the last failure', () async {
      final c = client([connectionError, connectionError, connectionError]);

      await expectLater(
        c.dio.get<dynamic>('/thing'),
        throwsA(isA<DioException>()),
      );
      expect(c.sent, hasLength(3), reason: '1 attempt + 2 retries');
    });

    test('a 503 is retried', () async {
      final c = client([(RequestOptions o) => status(o, 503), ok()]);

      final res = await c.dio.get<dynamic>('/thing');

      expect(res.statusCode, 200);
      expect(c.sent, hasLength(2));
    });

    test('a 429 is retried — the server asked us to come back', () async {
      final c = client([(RequestOptions o) => status(o, 429), ok()]);

      await c.dio.get<dynamic>('/thing');

      expect(c.sent, hasLength(2));
    });

    test('a timeout is retried', () async {
      final c = client([
        (RequestOptions o) => DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        ),
        ok(),
      ]);

      await c.dio.get<dynamic>('/thing');

      expect(c.sent, hasLength(2));
    });
  });

  group('does not retry', () {
    test('a 401 — a bad key fails identically on every attempt', () async {
      final c = client([(RequestOptions o) => status(o, 401)]);

      await expectLater(
        c.dio.get<dynamic>('/thing'),
        throwsA(isA<DioException>()),
      );
      expect(c.sent, hasLength(1));
    });

    test('a 404', () async {
      final c = client([(RequestOptions o) => status(o, 404)]);

      await expectLater(
        c.dio.get<dynamic>('/thing'),
        throwsA(isA<DioException>()),
      );
      expect(c.sent, hasLength(1));
    });

    test('a POST — repeating a write could double-apply it', () async {
      final c = client([connectionError, ok()]);

      await expectLater(
        c.dio.post<dynamic>('/rate'),
        throwsA(isA<DioException>()),
      );
      expect(c.sent, hasLength(1), reason: 'writes are never replayed');
    });

    test('a DELETE', () async {
      final c = client([connectionError, ok()]);

      await expectLater(
        c.dio.delete<dynamic>('/thing'),
        throwsA(isA<DioException>()),
      );
      expect(c.sent, hasLength(1));
    });

    test('a cancellation — the app abandoned this on purpose', () async {
      final c = client([
        (RequestOptions o) =>
            DioException(requestOptions: o, type: DioExceptionType.cancel),
      ]);

      await expectLater(
        c.dio.get<dynamic>('/thing'),
        throwsA(isA<DioException>()),
      );
      expect(c.sent, hasLength(1));
    });

    test('anything, when the client opts out with maxRetries: 0', () async {
      final c = client([connectionError, ok()], maxRetries: 0);

      await expectLater(
        c.dio.get<dynamic>('/thing'),
        throwsA(isA<DioException>()),
      );
      expect(c.sent, hasLength(1));
    });
  });

  group('client shape', () {
    test('still carries the shared Accept header and per-caller timeouts', () {
      final dio = buildJsonDio(
        baseUrl: 'https://example.test',
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 7),
        headers: {'Authorization': 'Bearer x'},
      );

      expect(dio.options.headers['Accept'], 'application/json');
      expect(dio.options.headers['Authorization'], 'Bearer x');
      expect(dio.options.connectTimeout, const Duration(seconds: 3));
      expect(dio.options.receiveTimeout, const Duration(seconds: 7));
    });
  });
}

/// Serves [_script] one entry per request: a [ResponseBody] to return, or a
/// `DioException Function(RequestOptions)` to throw. Runs off the end by
/// repeating its last entry, so a test only lists what it cares about.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this._script, this._sent);

  final List<Object> _script;
  final List<RequestOptions> _sent;
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _sent.add(options);
    final step = _script[math.min(_index++, _script.length - 1)];
    if (step is ResponseBody) return step;
    throw (step as DioException Function(RequestOptions))(options);
  }

  @override
  void close({bool force = false}) {}
}
