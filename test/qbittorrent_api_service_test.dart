import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/services/qbittorrent_api_service.dart';

void main() {
  group('formEncode', () {
    // The login body used to interpolate credentials raw. A password with an
    // `&` in it split the body into a third field, authentication failed, and
    // the only symptom was the generic "check username/password".
    test('escapes the characters that split a form body', () {
      expect(
        QBittorrentApiService.formEncode({
          'username': 'admin',
          'password': 'p&ss=w+rd',
        }),
        'username=admin&password=p%26ss%3Dw%2Brd',
      );
    });

    test('percent-encodes a space rather than writing a plus', () {
      // `+` is the HTML-form convention. qBittorrent parses these bodies with
      // Qt's QUrlQuery, which percent-decodes but does not read `+` as a
      // space — so `+` would arrive as a literal plus inside the password.
      expect(
        QBittorrentApiService.formEncode({'password': 'two words'}),
        'password=two%20words',
      );
    });

    test('a literal plus survives the round trip', () {
      expect(
        QBittorrentApiService.formEncode({'password': 'a+b'}),
        'password=a%2Bb',
      );
    });

    test('escapes the key as well as the value', () {
      expect(QBittorrentApiService.formEncode({'a&b': 'c'}), 'a%26b=c');
    });

    test('joins fields in insertion order', () {
      expect(
        QBittorrentApiService.formEncode({
          'hash': 'abc123',
          'id': '0|1|2',
          'priority': '7',
        }),
        'hash=abc123&id=0%7C1%7C2&priority=7',
      );
    });

    test('an empty body encodes to an empty string', () {
      expect(QBittorrentApiService.formEncode(const {}), isEmpty);
    });
  });

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
