import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/peer.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/tracker.dart';
import '../utils/constants.dart';
import '../utils/platform_utils.dart';
import 'app_logger.dart';
import 'torrent_engine.dart';

/// Service for interacting with qBittorrent Web API v2.
///
/// The reference [TorrentEngine]: it answers every optional member, so no
/// capability is declared away. It does *not* answer [streamUrl] — qBittorrent
/// is a downloader, and serving its partially-written files is
/// `LocalStreamingServer`'s job.
///
/// Every authenticated call goes through [_request], which logs in when there
/// is no session yet and once more when qBittorrent answers 403 — which it
/// does to every request after it restarts, because sessions do not survive
/// a restart. Before that, a restarted qBittorrent made every call quietly
/// return an empty list until the connection check gave up on it.
class QBittorrentApiService extends TorrentEngine {
  QBittorrentApiService({
    String host = AppConstants.defaultHost,
    int port = AppConstants.defaultPort,
    String username = AppConstants.defaultUsername,
    String password = AppConstants.defaultPassword,
    @visibleForTesting HttpClientAdapter? httpClientAdapter,
  }) : _host = host,
       _port = port,
       _username = username,
       _password = password,
       _dio = Dio(
         BaseOptions(
           baseUrl: 'http://$host:$port',
           connectTimeout: const Duration(seconds: 10),
           receiveTimeout: const Duration(seconds: 10),
           headers: {
             'Referer': 'http://$host:$port',
             'Origin': 'http://$host:$port',
           },
           // 4xx is an answer here, not an exception: 403 drives re-login,
           // 404 the v4/v5 endpoint fallbacks, 409 a rejected add.
           validateStatus: (status) => status != null && status < 500,
         ),
       ) {
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final cookie = _sessionCookie;
          if (cookie != null) options.headers['Cookie'] = cookie;
          _log('API Request: ${options.method} ${options.path}');
          handler.next(options);
        },
        onResponse: (response, handler) {
          _log(
            'API Response: ${response.statusCode} '
            '${response.requestOptions.path}',
          );
          handler.next(response);
        },
        onError: (error, handler) {
          _log('API Error: ${error.message}');
          handler.next(error);
        },
      ),
    );
  }

  final Dio _dio;
  final String _host;
  final int _port;
  final String _username;
  final String _password;

  // No setters: a settings change disposes this service and builds a new one
  // through `torrentEngineProvider`, which is also what keeps the session,
  // `_pieceSizeCache` and `_syncRid` from going stale against another host.

  /// The session cookie exactly as qBittorrent set it, `name=value`.
  ///
  /// Kept whole because the name is not fixed: `SID` up to 5.1, `QBT_SID_<port>`
  /// from 5.2, and whatever the user configured where the name is
  /// customisable. Sending back a hard-coded `SID=` meant a correct password
  /// still failed every request after the login.
  String? _sessionCookie;
  bool _isAuthenticated = false;
  Future<bool>? _loginInFlight;
  int _syncRid = 0;
  final Map<String, int> _pieceSizeCache = {};

  /// True when the HTTP status code is in the 2xx success range.
  ///
  /// qBittorrent 5.2.0 changed empty-body responses from 200 to 204, so a
  /// strict `== 200` check rejects valid successes on the latest qBit. Use
  /// this everywhere we treat the response as a success/failure boolean.
  @visibleForTesting
  static bool isSuccessStatus(int? code) =>
      code != null && code >= 200 && code < 300;

  /// Form-encode a request body.
  ///
  /// The login body used to interpolate the username and password raw, so a
  /// password containing `&`, `=`, `+`, `%` or a space produced a malformed
  /// body — and the only symptom was a generic authentication failure. The
  /// hash and id parameters are hex and integers today, but they go through
  /// the same door so the next parameter added cannot reintroduce it.
  ///
  /// [Uri.encodeComponent], **not** [Uri.encodeQueryComponent]: the two differ
  /// only on the space, which the latter writes as `+`. That is an HTML-form
  /// convention, and qBittorrent parses these bodies with Qt's `QUrlQuery`,
  /// which percent-decodes but does not turn `+` back into a space — so a
  /// password with a space in it would arrive with a literal `+`.
  @visibleForTesting
  static String formEncode(Map<String, String> fields) => fields.entries
      .map(
        (e) =>
            '${Uri.encodeComponent(e.key)}='
            '${Uri.encodeComponent(e.value)}',
      )
      .join('&');

  /// The session cookie among a response's `Set-Cookie` headers, as the
  /// `name=value` pair to send back — or null when there is none.
  ///
  /// Prefers a name containing `SID` (qBittorrent's own choices), and
  /// otherwise takes the first cookie with a value, since qBittorrent sets no
  /// other cookie on login and the name may be user-defined. An empty value
  /// is a deletion, not a session.
  @visibleForTesting
  static String? sessionCookieFrom(List<String>? setCookieHeaders) {
    if (setCookieHeaders == null) return null;
    String? firstNamed;
    for (final header in setCookieHeaders) {
      final pair = header.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      if (name.toUpperCase().contains('SID')) return '$name=$value';
      firstNamed ??= '$name=$value';
    }
    return firstNamed;
  }

  /// Whether a login response means we are in.
  ///
  /// qBittorrent up to 5.1 answers 200 with `Ok.`; 5.2 answers with an empty
  /// body and a session cookie. `Fails.` is a wrong username or password, and
  /// a 403 is an IP banned after too many of those.
  @visibleForTesting
  static bool loginSucceeded({
    required int? statusCode,
    required Object? body,
    required String? sessionCookie,
  }) {
    if (!isSuccessStatus(statusCode)) return false;
    final text = body?.toString().trim() ?? '';
    if (text == 'Ok.') return true;
    if (text.isEmpty) return sessionCookie != null;
    return false;
  }

  static final Options _formOptions = Options(
    contentType: 'application/x-www-form-urlencoded',
  );

  /// Get API base URL
  @override
  String get baseUrl => 'http://$_host:$_port';

  // ==================== Auth ====================

  void _clearSession() {
    _sessionCookie = null;
    _isAuthenticated = false;
  }

  /// Log in to qBittorrent.
  ///
  /// Concurrent callers share one attempt: after a qBittorrent restart every
  /// in-flight poll gets a 403 at once, and each logging in separately would
  /// also trip qBittorrent's failed-login ban if the password is wrong.
  ///
  /// Returns false when qBittorrent refused the credentials. Throws the
  /// [DioException] when it could not be reached at all, so the caller can
  /// say which of the two happened.
  @override
  Future<bool> login() =>
      _loginInFlight ??= _login().whenComplete(() => _loginInFlight = null);

  Future<bool> _login() async {
    _clearSession();

    // qBittorrent can be set to skip authentication for localhost or a
    // whitelisted subnet; then an anonymous request simply works.
    try {
      final probe = await _dio.get<dynamic>('/api/v2/app/version');
      if (isSuccessStatus(probe.statusCode)) {
        _isAuthenticated = true;
        _log('Connected without a login (authentication bypassed)');
        return true;
      }
    } on DioException catch (e) {
      // An unreachable server fails the login below the same way; let that
      // one be the error the caller sees.
      _log('Anonymous probe failed (${e.type}) — trying a normal login');
    }

    final response = await _dio.post<dynamic>(
      '/api/v2/auth/login',
      data: formEncode({'username': _username, 'password': _password}),
      options: _formOptions,
    );
    final cookie = sessionCookieFrom(response.headers['set-cookie']);
    if (loginSucceeded(
      statusCode: response.statusCode,
      body: response.data,
      sessionCookie: cookie,
    )) {
      _sessionCookie = cookie;
      _isAuthenticated = true;
      // The name only — the value is a credential and the log is plain text.
      final name = cookie?.split('=').first;
      _log('Logged in${name == null ? '' : ' (session cookie $name)'}');
      return true;
    }

    _log('Login refused: ${response.statusCode} ${response.data}');
    return false;
  }

  /// One authenticated request.
  ///
  /// Logs in first when there is no session, and once more on a 403 — the
  /// answer to a session qBittorrent no longer knows about. Null when the
  /// engine could not be reached, or refused us after the fresh login too.
  /// Never throws.
  Future<Response<dynamic>?> _request(
    String what,
    Future<Response<dynamic>> Function() send,
  ) async {
    try {
      if (!_isAuthenticated && !await login()) return null;
      var response = await send();
      if (response.statusCode == 403) {
        _log('$what: session rejected (403) — logging in again');
        _clearSession();
        if (!await login()) return null;
        response = await send();
      }
      return response;
    } catch (e) {
      _log('$what failed: $e');
      return null;
    }
  }

  Future<Response<dynamic>?> _get(
    String what,
    String path, {
    Map<String, dynamic>? query,
  }) => _request(what, () => _dio.get<dynamic>(path, queryParameters: query));

  Future<Response<dynamic>?> _post(
    String what,
    String path, [
    Map<String, String> fields = const {},
  ]) => _request(
    what,
    () => _dio.post<dynamic>(
      path,
      data: formEncode(fields),
      options: _formOptions,
    ),
  );

  Future<bool> _postOk(
    String what,
    String path, [
    Map<String, String> fields = const {},
  ]) async => isSuccessStatus((await _post(what, path, fields))?.statusCode);

  // ==================== App ====================

  /// Get qBittorrent version
  @override
  Future<String?> getVersion() async {
    final response = await _get('get version', '/api/v2/app/version');
    if (!isSuccessStatus(response?.statusCode)) return null;
    return response?.data?.toString().trim();
  }

  /// Reachability probe, including a quiet re-login after a restart.
  @override
  Future<bool> testConnection() async => isSuccessStatus(
    (await _get('check connection', '/api/v2/app/version'))?.statusCode,
  );

  /// Ask qBittorrent to quit, the way its own File → Exit does: resume data
  /// is saved and every torrent is shut down cleanly.
  ///
  /// Only for an instance this app launched — see
  /// `QBittorrentProcessService.launchedThisSession`.
  Future<bool> requestShutdown() =>
      _postOk('quit qBittorrent', '/api/v2/app/shutdown');

  // ==================== Torrents ====================

  @override
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes}) async {
    final response = await _get(
      'list torrents',
      '/api/v2/torrents/info',
      query: hashes == null ? null : {'hashes': hashes.join('|')},
    );
    if (response == null || !isSuccessStatus(response.statusCode)) return null;
    final data = response.data;
    if (data is! List) return null;
    return data
        .whereType<Map>()
        .map((json) => Torrent.fromJson(json.cast<String, dynamic>()))
        .toList();
  }

  /// Piece size is not on `/torrents/info` — only on `/torrents/properties`.
  /// Cached because it never changes for a given hash.
  @override
  Future<int> getPieceSize(String hash) async {
    final cached = _pieceSizeCache[hash];
    if (cached != null && cached > 0) return cached;
    final response = await _get(
      'get piece size',
      '/api/v2/torrents/properties',
      query: {'hash': hash},
    );
    final data = response?.data;
    if (!isSuccessStatus(response?.statusCode) || data is! Map) return 0;
    final size = (data['piece_size'] as num?)?.toInt() ?? 0;
    if (size > 0) _pieceSizeCache[hash] = size;
    return size;
  }

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async {
    final response = await _get(
      'list files',
      '/api/v2/torrents/files',
      query: {'hash': hash},
    );
    if (response == null) return null;
    // An unknown hash is an answer — there is nothing there — not an outage.
    if (response.statusCode == 404) return <TorrentFile>[];
    if (!isSuccessStatus(response.statusCode)) return null;
    final data = response.data;
    if (data is! List) return null;
    return [
      for (var i = 0; i < data.length; i++)
        if (data[i] is Map)
          TorrentFile.fromJson((data[i] as Map).cast<String, dynamic>(), i),
    ];
  }

  @override
  Future<List<Tracker>> getTorrentTrackers(String hash) async {
    final response = await _get(
      'list trackers',
      '/api/v2/torrents/trackers',
      query: {'hash': hash},
    );
    final data = response?.data;
    if (!isSuccessStatus(response?.statusCode) || data is! List) {
      return const [];
    }
    return data
        .whereType<Map>()
        .map((json) => Tracker.fromJson(json.cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<List<Peer>> getTorrentPeers(String hash) async {
    final response = await _get(
      'list peers',
      '/api/v2/sync/torrentPeers',
      query: {'hash': hash, 'rid': 0},
    );
    final data = response?.data;
    if (!isSuccessStatus(response?.statusCode) || data is! Map) {
      return const [];
    }
    final peers = data['peers'];
    if (peers is! Map) return const [];
    return [
      for (final entry in peers.entries)
        if (entry.value is Map)
          Peer.fromJson(
            entry.key.toString(),
            (entry.value as Map).cast<String, dynamic>(),
          ),
    ];
  }

  /// Add torrent from magnet link or file
  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    bool? paused,
    bool? sequentialDownload,
  }) async {
    // Built per attempt: a FormData is consumed by sending it, so the retry
    // after a re-login needs a fresh one.
    Future<FormData> form() async {
      final formData = FormData();
      if (magnetLink != null) {
        formData.fields.add(MapEntry('urls', magnetLink));
      }
      if (torrentFile != null) {
        formData.files.add(
          MapEntry(
            'torrents',
            await MultipartFile.fromFile(
              torrentFile.path,
              filename: basenameOf(torrentFile.path),
            ),
          ),
        );
      }
      if (savePath != null) formData.fields.add(MapEntry('savepath', savePath));
      if (paused != null) {
        // qBittorrent 4.x uses 'paused'; 5.0+ uses 'stopped'. Send both —
        // each version ignores the field it doesn't recognise.
        formData.fields.add(MapEntry('paused', paused.toString()));
        formData.fields.add(MapEntry('stopped', paused.toString()));
      }
      if (sequentialDownload != null) {
        formData.fields.add(
          MapEntry('sequentialDownload', sequentialDownload.toString()),
        );
      }
      return formData;
    }

    final response = await _request(
      'add torrent',
      () async =>
          _dio.post<dynamic>('/api/v2/torrents/add', data: await form()),
    );
    // qBittorrent 4.x returns 200 + body "Ok." on success and 200 + body
    // "Fails." on failure. qBittorrent 5.2+ returns 204 with empty body on
    // success and 4xx on failure. Treat any 2xx + non-failure body as
    // success rather than relying on the exact "Ok." literal.
    if (!isSuccessStatus(response?.statusCode)) return false;
    final body = response?.data?.toString().trim().toLowerCase() ?? '';
    return body != 'fails.';
  }

  /// Pause (stop) torrents
  @override
  Future<bool> pauseTorrents(List<String> hashes) async {
    final fields = {'hashes': hashes.join('|')};
    // 5.x calls it stop; 4.x answers 404 to that and wants pause.
    var response = await _post('pause', '/api/v2/torrents/stop', fields);
    if (response?.statusCode == 404) {
      response = await _post('pause', '/api/v2/torrents/pause', fields);
    }
    return isSuccessStatus(response?.statusCode);
  }

  /// Resume (start) torrents
  @override
  Future<bool> resumeTorrents(List<String> hashes) async {
    final fields = {'hashes': hashes.join('|')};
    // 5.x calls it start; 4.x answers 404 to that and wants resume.
    var response = await _post('resume', '/api/v2/torrents/start', fields);
    if (response?.statusCode == 404) {
      response = await _post('resume', '/api/v2/torrents/resume', fields);
    }
    return isSuccessStatus(response?.statusCode);
  }

  /// Delete torrents
  @override
  Future<bool> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async {
    final ok = await _postOk('delete', '/api/v2/torrents/delete', {
      'hashes': hashes.join('|'),
      'deleteFiles': '$deleteFiles',
    });
    // Force a full snapshot on the next sync — the maindata RID can miss the
    // deletion delta if the call lands between polls.
    if (ok) _syncRid = 0;
    return ok;
  }

  @override
  Future<bool> recheckTorrents(List<String> hashes) => _postOk(
    'recheck',
    '/api/v2/torrents/recheck',
    {'hashes': hashes.join('|')},
  );

  @override
  Future<bool> reannounceTorrents(List<String> hashes) => _postOk(
    'reannounce',
    '/api/v2/torrents/reannounce',
    {'hashes': hashes.join('|')},
  );

  @override
  Future<bool> setFilePriority(String hash, List<int> fileIds, int priority) =>
      _postOk('set file priority', '/api/v2/torrents/filePrio', {
        'hash': hash,
        'id': fileIds.join('|'),
        'priority': '$priority',
      });

  // ==================== Transfer ====================

  @override
  Future<bool> setDownloadLimit(int limit) => _postOk(
    'set download limit',
    '/api/v2/transfer/setDownloadLimit',
    {'limit': '$limit'},
  );

  @override
  Future<bool> setUploadLimit(int limit) => _postOk(
    'set upload limit',
    '/api/v2/transfer/setUploadLimit',
    {'limit': '$limit'},
  );

  // ==================== Sync ====================

  /// Get main data using sync endpoint (efficient polling)
  @override
  Future<Map<String, dynamic>?> getMainData({bool fullUpdate = false}) async {
    final response = await _get(
      'sync',
      '/api/v2/sync/maindata',
      query: {'rid': fullUpdate ? 0 : _syncRid},
    );
    final data = response?.data;
    if (!isSuccessStatus(response?.statusCode) || data is! Map) return null;
    final map = data.cast<String, dynamic>();
    final rid = map['rid'];
    if (rid is int) _syncRid = rid;
    return map;
  }

  // ==================== Streaming ====================

  /// qBittorrent's Web API expects `hashes` in the form-encoded body for the
  /// toggle endpoints, not as a query parameter — passing it as a query param
  /// silently no-ops on at least some builds.
  Future<bool> _toggleSequentialDownload(String hash) => _postOk(
    'toggle sequential download',
    '/api/v2/torrents/toggleSequentialDownload',
    {'hashes': hash},
  );

  Future<bool> _toggleFirstLastPiecePrio(String hash) => _postOk(
    'toggle first/last piece priority',
    '/api/v2/torrents/toggleFirstLastPiecePrio',
    {'hashes': hash},
  );

  Future<Torrent?> _torrent(String hash) async {
    final torrents = await tryGetTorrents(hashes: [hash]);
    return (torrents == null || torrents.isEmpty) ? null : torrents.first;
  }

  /// Sequential on, first/last piece priority off.
  ///
  /// qBittorrent only exposes toggles. [resetPicker] turns sequential off
  /// then on so the piece picker starts at the first wanted piece of this
  /// file instead of wherever a previous session left it — without that,
  /// season-pack streaming fills random pieces and the player waits until
  /// ~99%.
  @override
  Future<bool> ensureInOrderDownload(
    String hash, {
    bool resetPicker = false,
  }) async {
    var torrent = await _torrent(hash);
    if (torrent == null) return false;

    if (resetPicker) {
      if (torrent.sequentialDownload) await _toggleSequentialDownload(hash);
      await _toggleSequentialDownload(hash);
      _log('sequential download reset on for $hash');
    } else if (!torrent.sequentialDownload) {
      await _toggleSequentialDownload(hash);
      _log('sequential download enabled for $hash');
    }

    torrent = await _torrent(hash) ?? torrent;
    if (torrent.firstLastPiecePriority) {
      await _toggleFirstLastPiecePrio(hash);
      _log('first/last piece prio disabled for $hash');
      torrent = await _torrent(hash) ?? torrent;
    }

    _log(
      'in-order seq=${torrent.sequentialDownload} '
      'fl_prio=${torrent.firstLastPiecePriority} for $hash',
    );
    return torrent.sequentialDownload;
  }

  /// Get piece states for a torrent (0=not downloaded, 1=downloading, 2=downloaded)
  @override
  Future<List<int>?> getPieceStates(String hash) async {
    final response = await _get(
      'get piece states',
      '/api/v2/torrents/pieceStates',
      query: {'hash': hash},
    );
    final data = response?.data;
    if (!isSuccessStatus(response?.statusCode) || data is! List) return null;
    return data.map((e) => (e as num).toInt()).toList();
  }

  /// Log a message, tagged once here.
  void _log(String message) => AppLog.d('[QBittorrentAPI] $message');

  @override
  void dispose() {
    _dio.close();
  }
}
