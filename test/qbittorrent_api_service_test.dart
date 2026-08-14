import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/services/qbittorrent_api_service.dart';

void main() {
  group('isSuccessStatus', () {
    test('accepts the whole 2xx range', () {
      expect(QBittorrentApiService.isSuccessStatus(200), isTrue);
      // qBittorrent 5.2.0 returns 204 for empty-body successes.
      expect(QBittorrentApiService.isSuccessStatus(204), isTrue);
      expect(QBittorrentApiService.isSuccessStatus(299), isTrue);
    });

    test('rejects everything outside 2xx', () {
      expect(QBittorrentApiService.isSuccessStatus(199), isFalse);
      expect(QBittorrentApiService.isSuccessStatus(300), isFalse);
      expect(QBittorrentApiService.isSuccessStatus(403), isFalse);
      expect(QBittorrentApiService.isSuccessStatus(500), isFalse);
    });

    test('rejects a null status', () {
      expect(QBittorrentApiService.isSuccessStatus(null), isFalse);
    });
  });
}
