import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrent_action_result.dart';
import 'package:mediahub/providers/torrent_provider.dart';

DioException _dio(DioExceptionType type, {int? statusCode, String? message}) {
  final options = RequestOptions(path: '/api/v2/torrents/pause');
  return DioException(
    requestOptions: options,
    type: type,
    message: message,
    response: statusCode == null
        ? null
        : Response<dynamic>(requestOptions: options, statusCode: statusCode),
  );
}

void main() {
  group('TorrentActionResult', () {
    test('success carries no error', () {
      const result = TorrentActionResult.success();
      expect(result.success, isTrue);
      expect(result.error, isNull);
    });

    test('failure is not success and keeps the cause', () {
      const result = TorrentActionResult.failure('Cannot reach qBittorrent');
      expect(result.success, isFalse);
      expect(result.error, 'Cannot reach qBittorrent');
    });
  });

  group('describeEngineError', () {
    // Shown to users of either engine — the built-in one has no qBittorrent
    // to blame — and never as raw exception text.
    test('maps every timeout flavour to one phrase', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(
          describeEngineError(_dio(type)),
          "The torrent engine didn't answer in time",
        );
      }
    });

    test(
      'names an unreachable engine rather than leaking the socket error',
      () {
        expect(
          describeEngineError(_dio(DioExceptionType.connectionError)),
          "Can't reach the torrent engine",
        );
      },
    );

    test('includes the status code on a bad response', () {
      expect(
        describeEngineError(
          _dio(DioExceptionType.badResponse, statusCode: 403),
        ),
        'The torrent engine reported an error (HTTP 403)',
      );
    });

    test('handles a bad response with no status code', () {
      expect(
        describeEngineError(_dio(DioExceptionType.badResponse)),
        'The torrent engine reported an error',
      );
    });

    test('never repeats raw exception text', () {
      for (final error in <Object>[
        StateError('boom'),
        _dio(DioExceptionType.unknown, message: 'SocketException: boom'),
      ]) {
        final described = describeEngineError(error);
        expect(described, isNotEmpty);
        expect(described, isNot(contains('boom')));
        expect(described.toLowerCase(), isNot(contains('qbittorrent')));
      }
    });
  });
}
