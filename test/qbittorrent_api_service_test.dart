import 'dart:typed_data';

import 'package:dio/dio.dart';
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

  _sessionTests();
}

/// A Dio adapter that answers from a script, so the login and re-login
/// sequences can be exercised without a qBittorrent.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.answer);

  final Future<ResponseBody> Function(RequestOptions request) answer;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _reply(
  int status, {
  String body = '',
  bool json = false,
  List<String> setCookie = const [],
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [json ? 'application/json' : 'text/plain'],
    if (setCookie.isNotEmpty) 'set-cookie': setCookie,
  },
);

QBittorrentApiService _service(_ScriptedAdapter adapter) {
  final service = QBittorrentApiService(
    username: 'admin',
    password: 'secret',
    httpClientAdapter: adapter,
  );
  addTearDown(service.dispose);
  return service;
}

void _sessionTests() {
  group('sessionCookieFrom', () {
    test('keeps the whole name=value pair, whatever the name', () {
      expect(
        QBittorrentApiService.sessionCookieFrom([
          'QBT_SID_8080=abc123; HttpOnly; SameSite=Strict; path=/',
        ]),
        'QBT_SID_8080=abc123',
      );
      expect(
        QBittorrentApiService.sessionCookieFrom(['SID=xyz; path=/']),
        'SID=xyz',
      );
      expect(
        QBittorrentApiService.sessionCookieFrom(['webui_session=v1; path=/']),
        'webui_session=v1',
      );
    });

    test('prefers an SID-named cookie over others', () {
      expect(
        QBittorrentApiService.sessionCookieFrom([
          'theme=dark; path=/',
          'QBT_SID_9090=s; path=/',
        ]),
        'QBT_SID_9090=s',
      );
    });

    test('an emptied cookie is a deletion, not a session', () {
      expect(
        QBittorrentApiService.sessionCookieFrom(['SID=; Max-Age=0']),
        isNull,
      );
      expect(QBittorrentApiService.sessionCookieFrom(null), isNull);
    });
  });

  group('loginSucceeded', () {
    test('4.x: 200 with Ok.', () {
      expect(
        QBittorrentApiService.loginSucceeded(
          statusCode: 200,
          body: 'Ok.',
          sessionCookie: 'SID=x',
        ),
        isTrue,
      );
    });

    test('5.2: an empty body with a session cookie', () {
      for (final status in [200, 204]) {
        expect(
          QBittorrentApiService.loginSucceeded(
            statusCode: status,
            body: '',
            sessionCookie: 'QBT_SID_8080=x',
          ),
          isTrue,
          reason: 'HTTP $status',
        );
      }
    });

    test('Fails., a ban, or an empty body with no session are failures', () {
      expect(
        QBittorrentApiService.loginSucceeded(
          statusCode: 200,
          body: 'Fails.',
          sessionCookie: null,
        ),
        isFalse,
      );
      expect(
        QBittorrentApiService.loginSucceeded(
          statusCode: 403,
          body: 'Your IP address has been banned',
          sessionCookie: null,
        ),
        isFalse,
      );
      expect(
        QBittorrentApiService.loginSucceeded(
          statusCode: 204,
          body: '',
          sessionCookie: null,
        ),
        isFalse,
      );
    });
  });

  group('session handling over HTTP', () {
    test(
      'qBittorrent 5.2: logs in and sends the cookie back as named',
      () async {
        final adapter = _ScriptedAdapter((r) async {
          if (r.path == '/api/v2/app/version') return _reply(403);
          if (r.path == '/api/v2/auth/login') {
            return _reply(
              204,
              setCookie: ['QBT_SID_8080=abc; HttpOnly; path=/'],
            );
          }
          if (r.path == '/api/v2/torrents/info') {
            return r.headers['Cookie'] == 'QBT_SID_8080=abc'
                ? _reply(200, body: '[]', json: true)
                : _reply(403);
          }
          return _reply(404);
        });
        final api = _service(adapter);

        expect(await api.login(), isTrue);
        expect(await api.tryGetTorrents(), isEmpty);
        final listing = adapter.requests.last;
        expect(listing.headers['Cookie'], 'QBT_SID_8080=abc');
      },
    );

    test('qBittorrent 4.x: Ok. with an SID cookie', () async {
      final adapter = _ScriptedAdapter((r) async {
        if (r.path == '/api/v2/app/version') return _reply(403);
        if (r.path == '/api/v2/auth/login') {
          return _reply(200, body: 'Ok.', setCookie: ['SID=xyz; path=/']);
        }
        return r.headers['Cookie'] == 'SID=xyz'
            ? _reply(200, body: '[]', json: true)
            : _reply(403);
      });
      final api = _service(adapter);

      expect(await api.tryGetTorrents(), isEmpty);
    });

    test('a wrong password is a refusal, not an outage', () async {
      final adapter = _ScriptedAdapter((r) async {
        if (r.path == '/api/v2/auth/login') return _reply(200, body: 'Fails.');
        return _reply(403);
      });
      final api = _service(adapter);

      expect(await api.login(), isFalse);
      expect(
        await api.tryGetTorrents(),
        isNull,
        reason: 'could not be asked — not "no torrents"',
      );
    });

    test('logs in again once on a 403 and retries', () async {
      // qBittorrent forgets every session when it restarts.
      var logins = 0;
      String? validSession;
      final adapter = _ScriptedAdapter((r) async {
        if (r.path == '/api/v2/app/version') return _reply(403);
        if (r.path == '/api/v2/auth/login') {
          logins++;
          validSession = 'SID=session$logins';
          return _reply(204, setCookie: ['$validSession; path=/']);
        }
        if (r.path == '/api/v2/torrents/info') {
          return r.headers['Cookie'] == validSession
              ? _reply(200, body: '[]', json: true)
              : _reply(403);
        }
        return _reply(404);
      });
      final api = _service(adapter);

      expect(await api.login(), isTrue);
      validSession = null; // qBittorrent restarted
      expect(await api.tryGetTorrents(), isEmpty);
      expect(logins, 2, reason: 'one re-login, not a loop');
    });

    test('gives up after one re-login if it is refused again', () async {
      var logins = 0;
      final adapter = _ScriptedAdapter((r) async {
        if (r.path == '/api/v2/auth/login') {
          logins++;
          return _reply(204, setCookie: ['SID=s$logins; path=/']);
        }
        return _reply(403);
      });
      final api = _service(adapter);

      expect(await api.tryGetTorrents(), isNull);
      expect(logins, 2);
    });

    test('an unreachable server throws from login and lists as null', () async {
      final adapter = _ScriptedAdapter(
        (r) async => throw DioException.connectionError(
          requestOptions: r,
          reason: 'Connection refused',
        ),
      );
      final api = _service(adapter);

      await expectLater(api.login(), throwsA(isA<DioException>()));
      expect(await api.tryGetTorrents(), isNull);
      expect(await api.testConnection(), isFalse);
    });

    test('asks qBittorrent to quit through its own API', () async {
      final adapter = _ScriptedAdapter((r) async {
        if (r.path == '/api/v2/app/version') return _reply(200, body: 'v5');
        if (r.path == '/api/v2/app/shutdown') return _reply(200);
        return _reply(404);
      });
      final api = _service(adapter);

      expect(await api.requestShutdown(), isTrue);
      expect(adapter.requests.last.method, 'POST');
    });
  });
}
