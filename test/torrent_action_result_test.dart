import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/services/qbittorrent_api_service.dart';

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

    test('messageOr returns the bare fallback on success', () {
      const result = TorrentActionResult.success();
      expect(
        result.messageOr('Failed to pause torrent'),
        'Failed to pause torrent',
      );
    });

    test('messageOr appends the cause on failure', () {
      const result = TorrentActionResult.failure('Cannot reach qBittorrent');
      expect(
        result.messageOr('Failed to pause torrent'),
        'Failed to pause torrent — Cannot reach qBittorrent',
      );
    });
  });

  group('describeQbError', () {
    test('unwraps a QBittorrentApiException to its message', () {
      expect(
        describeQbError(QBittorrentApiException('Torrent not found')),
        'Torrent not found',
      );
    });

    test('maps every timeout flavour to one phrase', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(describeQbError(_dio(type)), 'qBittorrent timed out');
      }
    });

    test('names an unreachable host rather than leaking the socket error', () {
      expect(
        describeQbError(_dio(DioExceptionType.connectionError)),
        'Cannot reach qBittorrent',
      );
    });

    test('includes the status code on a bad response', () {
      expect(
        describeQbError(_dio(DioExceptionType.badResponse, statusCode: 403)),
        'qBittorrent returned HTTP 403',
      );
    });

    test('handles a bad response with no status code', () {
      expect(
        describeQbError(_dio(DioExceptionType.badResponse)),
        'qBittorrent returned an error',
      );
    });

    test('falls back to the Dio message for other types', () {
      expect(
        describeQbError(_dio(DioExceptionType.cancel, message: 'cancelled')),
        'cancelled',
      );
    });

    test('never returns an empty string for an unknown error', () {
      final described = describeQbError(StateError('boom'));
      expect(described, isNotEmpty);
      expect(described, contains('boom'));
    });
  });
}
