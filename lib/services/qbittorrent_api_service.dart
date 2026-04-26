import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/peer.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/tracker.dart';
import '../utils/constants.dart';

/// Exception for qBittorrent API errors
class QBittorrentApiException implements Exception {
  final String message;
  final int? statusCode;

  QBittorrentApiException(this.message, {this.statusCode});

  @override
  String toString() =>
      'QBittorrentApiException: $message (status: $statusCode)';
}

/// Service for interacting with qBittorrent Web API v2
class QBittorrentApiService {
  late Dio _dio;
  String _host;
  int _port;
  String _username;
  String _password;
  String? _sid;
  bool _isAuthenticated = false;
  int _syncRid = 0;

  /// Callback for logging
  final void Function(String message)? onLog;

  QBittorrentApiService({
    String host = AppConstants.defaultHost,
    int port = AppConstants.defaultPort,
    String username = AppConstants.defaultUsername,
    String password = AppConstants.defaultPassword,
    this.onLog,
  }) : _host = host,
       _port = port,
       _username = username,
       _password = password {
    _initDio();
  }

  /// Initialize Dio client
  void _initDio() {
    _dio = Dio(
      BaseOptions(
        baseUrl: 'http://$_host:$_port',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'Referer': 'http://$_host:$_port',
          'Origin': 'http://$_host:$_port',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    // Add interceptor for logging and auth
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (_sid != null) {
            options.headers['Cookie'] = 'SID=$_sid';
          }
          _log('API Request: ${options.method} ${options.path}');
          return handler.next(options);
        },
        onResponse: (response, handler) {
          _log(
            'API Response: ${response.statusCode} ${response.requestOptions.path}',
          );
          return handler.next(response);
        },
        onError: (error, handler) {
          _log('API Error: ${error.message}');
          return handler.next(error);
        },
      ),
    );
  }

  /// Update connection settings
  void updateSettings({
    String? host,
    int? port,
    String? username,
    String? password,
  }) {
    if (host != null) _host = host;
    if (port != null) _port = port;
    if (username != null) _username = username;
    if (password != null) _password = password;

    _initDio();
    _isAuthenticated = false;
    _sid = null;
  }

  /// Check if authenticated
  bool get isAuthenticated => _isAuthenticated;

  /// Get API base URL
  String get baseUrl => 'http://$_host:$_port';

  // ==================== Auth ====================

  /// Login to qBittorrent
  Future<bool> login() async {
    try {
      // First, try to access the API without authentication
      // qBittorrent may have "bypass authentication for localhost" enabled
      final testResponse = await _dio.get('/api/v2/app/version');
      if (testResponse.statusCode == 200) {
        // Extract SID from any response cookies
        final cookies = testResponse.headers['set-cookie'];
        if (cookies != null) {
          for (final cookie in cookies) {
            if (cookie.contains('SID=')) {
              final match = RegExp(r'SID=([^;]+)').firstMatch(cookie);
              if (match != null) {
                _sid = match.group(1);
              }
            }
          }
        }
        _isAuthenticated = true;
        _log('Connected without authentication (localhost bypass enabled)');
        return true;
      }
    } catch (e) {
      _log('Localhost bypass check failed, trying normal login: $e');
    }

    // Normal authentication
    try {
      final response = await _dio.post(
        '/api/v2/auth/login',
        data: 'username=$_username&password=$_password',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );

      if (response.statusCode == 200) {
        final cookies = response.headers['set-cookie'];
        if (cookies != null) {
          for (final cookie in cookies) {
            if (cookie.contains('SID=')) {
              final match = RegExp(r'SID=([^;]+)').firstMatch(cookie);
              if (match != null) {
                _sid = match.group(1);
                _isAuthenticated = true;
                _log('Login successful, SID: $_sid');
                return true;
              }
            }
          }
        }

        // Some versions return Ok. without cookie
        if (response.data == 'Ok.') {
          _isAuthenticated = true;
          _log('Login successful (no SID)');
          return true;
        }
      }

      _log('Login failed: ${response.statusCode} - ${response.data}');
      _isAuthenticated = false;
      return false;
    } on DioException catch (e) {
      _log('Login DioException: ${e.type} - ${e.message}');
      _isAuthenticated = false;
      rethrow;
    } catch (e) {
      _log('Login error: $e');
      _isAuthenticated = false;
      return false;
    }
  }

  /// Logout from qBittorrent
  Future<void> logout() async {
    try {
      await _dio.post('/api/v2/auth/logout');
    } catch (e) {
      _log('Logout error: $e');
    } finally {
      _sid = null;
      _isAuthenticated = false;
    }
  }

  /// Ensure authenticated before making API calls
  Future<bool> _ensureAuthenticated() async {
    if (!_isAuthenticated) {
      return await login();
    }
    return true;
  }

  // ==================== App ====================

  /// Get qBittorrent version
  Future<String?> getVersion() async {
    if (!await _ensureAuthenticated()) return null;

    try {
      final response = await _dio.get('/api/v2/app/version');
      return response.data as String?;
    } catch (e) {
      _log('Get version error: $e');
      return null;
    }
  }

  /// Get Web API version
  Future<String?> getApiVersion() async {
    if (!await _ensureAuthenticated()) return null;

    try {
      final response = await _dio.get('/api/v2/app/webapiVersion');
      return response.data as String?;
    } catch (e) {
      _log('Get API version error: $e');
      return null;
    }
  }

  /// Get application preferences
  Future<Map<String, dynamic>?> getPreferences() async {
    if (!await _ensureAuthenticated()) return null;

    try {
      final response = await _dio.get('/api/v2/app/preferences');
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      _log('Get preferences error: $e');
      return null;
    }
  }

  /// Set application preferences
  Future<bool> setPreferences(Map<String, dynamic> prefs) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final prefsJson = jsonEncode(prefs);
      final response = await _dio.post(
        '/api/v2/app/setPreferences',
        data: 'json=${Uri.encodeComponent(prefsJson)}',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Set preferences error: $e');
      return false;
    }
  }

  // ==================== Torrents ====================

  /// Get all torrents
  Future<List<Torrent>> getTorrents({
    String? filter,
    String? category,
    String? tag,
    String? sort,
    bool? reverse,
    int? limit,
    int? offset,
    List<String>? hashes,
  }) async {
    if (!await _ensureAuthenticated()) return [];

    try {
      final params = <String, dynamic>{};
      if (filter != null) params['filter'] = filter;
      if (category != null) params['category'] = category;
      if (tag != null) params['tag'] = tag;
      if (sort != null) params['sort'] = sort;
      if (reverse != null) params['reverse'] = reverse;
      if (limit != null) params['limit'] = limit;
      if (offset != null) params['offset'] = offset;
      if (hashes != null) params['hashes'] = hashes.join('|');

      final response = await _dio.get(
        '/api/v2/torrents/info',
        queryParameters: params,
      );

      if (response.data is List) {
        return (response.data as List)
            .map((json) => Torrent.fromJson(json as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      _log('Get torrents error: $e');
      return [];
    }
  }

  /// Get torrent properties
  Future<Map<String, dynamic>?> getTorrentProperties(String hash) async {
    if (!await _ensureAuthenticated()) return null;

    try {
      final response = await _dio.get(
        '/api/v2/torrents/properties',
        queryParameters: {'hash': hash},
      );
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      _log('Get torrent properties error: $e');
      return null;
    }
  }

  /// Get torrent files
  Future<List<TorrentFile>> getTorrentFiles(String hash) async {
    if (!await _ensureAuthenticated()) return [];

    try {
      final response = await _dio.get(
        '/api/v2/torrents/files',
        queryParameters: {'hash': hash},
      );

      if (response.data is List) {
        final files = <TorrentFile>[];
        final list = response.data as List;
        for (var i = 0; i < list.length; i++) {
          files.add(TorrentFile.fromJson(list[i] as Map<String, dynamic>, i));
        }
        return files;
      }
      return [];
    } catch (e) {
      _log('Get torrent files error: $e');
      return [];
    }
  }

  /// Get torrent trackers
  Future<List<Tracker>> getTorrentTrackers(String hash) async {
    if (!await _ensureAuthenticated()) return [];

    try {
      final response = await _dio.get(
        '/api/v2/torrents/trackers',
        queryParameters: {'hash': hash},
      );

      if (response.data is List) {
        return (response.data as List)
            .map((json) => Tracker.fromJson(json as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      _log('Get torrent trackers error: $e');
      return [];
    }
  }

  /// Get torrent peers
  Future<List<Peer>> getTorrentPeers(String hash) async {
    if (!await _ensureAuthenticated()) return [];

    try {
      final response = await _dio.get(
        '/api/v2/sync/torrentPeers',
        queryParameters: {'hash': hash, 'rid': 0},
      );

      if (response.data is Map && response.data['peers'] != null) {
        final peersMap = response.data['peers'] as Map<String, dynamic>;
        return peersMap.entries
            .map((e) => Peer.fromJson(e.key, e.value as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      _log('Get torrent peers error: $e');
      return [];
    }
  }

  /// Add torrent from magnet link or URL
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    String? category,
    bool? paused,
    bool? skipChecking,
    bool? sequentialDownload,
    bool? firstLastPiecePrio,
  }) async {
    if (!await _ensureAuthenticated()) return false;

    try {
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
              filename: torrentFile.path.split('/').last,
            ),
          ),
        );
      }

      if (savePath != null) formData.fields.add(MapEntry('savepath', savePath));
      if (category != null) formData.fields.add(MapEntry('category', category));
      if (paused != null)
        formData.fields.add(MapEntry('paused', paused.toString()));
      if (skipChecking != null)
        formData.fields.add(MapEntry('skip_checking', skipChecking.toString()));
      if (sequentialDownload != null)
        formData.fields.add(
          MapEntry('sequentialDownload', sequentialDownload.toString()),
        );
      if (firstLastPiecePrio != null)
        formData.fields.add(
          MapEntry('firstLastPiecePrio', firstLastPiecePrio.toString()),
        );

      final response = await _dio.post('/api/v2/torrents/add', data: formData);

      return response.statusCode == 200 && response.data == 'Ok.';
    } catch (e) {
      _log('Add torrent error: $e');
      return false;
    }
  }

  /// Pause (stop) torrents
  Future<bool> pauseTorrents(List<String> hashes) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      // Try v5.x API first (stop), fall back to v4.x (pause)
      var response = await _dio.post(
        '/api/v2/torrents/stop',
        data: 'hashes=${hashes.join('|')}',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );

      // If stop endpoint doesn't exist (404), try legacy pause
      if (response.statusCode == 404) {
        response = await _dio.post(
          '/api/v2/torrents/pause',
          data: 'hashes=${hashes.join('|')}',
          options: Options(contentType: 'application/x-www-form-urlencoded'),
        );
      }

      return response.statusCode == 200;
    } catch (e) {
      _log('Pause torrents error: $e');
      return false;
    }
  }

  /// Resume (start) torrents
  Future<bool> resumeTorrents(List<String> hashes) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      // Try v5.x API first (start), fall back to v4.x (resume)
      var response = await _dio.post(
        '/api/v2/torrents/start',
        data: 'hashes=${hashes.join('|')}',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );

      // If start endpoint doesn't exist (404), try legacy resume
      if (response.statusCode == 404) {
        response = await _dio.post(
          '/api/v2/torrents/resume',
          data: 'hashes=${hashes.join('|')}',
          options: Options(contentType: 'application/x-www-form-urlencoded'),
        );
      }

      return response.statusCode == 200;
    } catch (e) {
      _log('Resume torrents error: $e');
      return false;
    }
  }

  /// Delete torrents
  Future<bool> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/torrents/delete',
        data: 'hashes=${hashes.join('|')}&deleteFiles=$deleteFiles',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Delete torrents error: $e');
      return false;
    }
  }

  /// Recheck torrents
  Future<bool> recheckTorrents(List<String> hashes) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/torrents/recheck',
        data: 'hashes=${hashes.join('|')}',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Recheck torrents error: $e');
      return false;
    }
  }

  /// Reannounce torrents to trackers
  Future<bool> reannounceTorrents(List<String> hashes) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/torrents/reannounce',
        data: 'hashes=${hashes.join('|')}',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Reannounce torrents error: $e');
      return false;
    }
  }

  /// Set torrent priority
  Future<bool> setTorrentPriority(List<String> hashes, String priority) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      String endpoint;
      switch (priority) {
        case 'top':
          endpoint = '/api/v2/torrents/topPrio';
          break;
        case 'bottom':
          endpoint = '/api/v2/torrents/bottomPrio';
          break;
        case 'increase':
          endpoint = '/api/v2/torrents/increasePrio';
          break;
        case 'decrease':
          endpoint = '/api/v2/torrents/decreasePrio';
          break;
        default:
          return false;
      }

      final response = await _dio.post(
        endpoint,
        data: 'hashes=${hashes.join('|')}',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Set torrent priority error: $e');
      return false;
    }
  }

  /// Set file priority
  Future<bool> setFilePriority(
    String hash,
    List<int> fileIds,
    int priority,
  ) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/torrents/filePrio',
        data: 'hash=$hash&id=${fileIds.join('|')}&priority=$priority',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Set file priority error: $e');
      return false;
    }
  }

  // ==================== Transfer ====================

  /// Get transfer info (global stats)
  Future<Map<String, dynamic>?> getTransferInfo() async {
    if (!await _ensureAuthenticated()) return null;

    try {
      final response = await _dio.get('/api/v2/transfer/info');
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      _log('Get transfer info error: $e');
      return null;
    }
  }

  /// Set global download speed limit
  Future<bool> setDownloadLimit(int limit) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/transfer/setDownloadLimit',
        data: 'limit=$limit',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Set download limit error: $e');
      return false;
    }
  }

  /// Set global upload speed limit
  Future<bool> setUploadLimit(int limit) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/transfer/setUploadLimit',
        data: 'limit=$limit',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Set upload limit error: $e');
      return false;
    }
  }

  // ==================== Sync ====================

  /// Get main data using sync endpoint (efficient polling)
  Future<Map<String, dynamic>?> getMainData({bool fullUpdate = false}) async {
    if (!await _ensureAuthenticated()) return null;

    try {
      final rid = fullUpdate ? 0 : _syncRid;
      final response = await _dio.get(
        '/api/v2/sync/maindata',
        queryParameters: {'rid': rid},
      );

      if (response.data is Map<String, dynamic>) {
        final data = response.data as Map<String, dynamic>;
        if (data['rid'] != null) {
          _syncRid = data['rid'] as int;
        }
        return data;
      }
      return null;
    } catch (e) {
      _log('Get main data error: $e');
      return null;
    }
  }

  /// Log a message
  void _log(String message) {
    if (kDebugMode) {
      print('[QBittorrentAPI] $message');
    }
    onLog?.call(message);
  }

  /// Toggle sequential download for a torrent.
  ///
  /// qBittorrent's WebAPI expects `hashes` in the form-encoded body for
  /// these toggle endpoints, not as a query parameter — passing it as a
  /// query param silently no-ops on at least some builds (returns 200 with
  /// an empty body but doesn't actually flip the flag, or returns a non-200
  /// depending on version). Match `setFilePriority` / `addTorrent` /
  /// `toggleFirstLastPiecePrio` and submit as form data.
  Future<bool> toggleSequentialDownload(String hash) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/torrents/toggleSequentialDownload',
        data: 'hashes=$hash',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Toggle sequential download error: $e');
      return false;
    }
  }

  /// Toggle first/last piece priority for a torrent. See
  /// [toggleSequentialDownload] for why `hashes` is form-encoded.
  Future<bool> toggleFirstLastPiecePrio(String hash) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      final response = await _dio.post(
        '/api/v2/torrents/toggleFirstLastPiecePrio',
        data: 'hashes=$hash',
        options: Options(contentType: 'application/x-www-form-urlencoded'),
      );
      return response.statusCode == 200;
    } catch (e) {
      _log('Toggle first/last piece priority error: $e');
      return false;
    }
  }

  /// Enable streaming mode for a torrent (sequential + first/last piece priority)
  Future<bool> enableStreamingMode(String hash) async {
    if (!await _ensureAuthenticated()) return false;

    try {
      // Get current torrent state
      final torrents = await getTorrents(hashes: [hash]);
      if (torrents.isEmpty) return false;

      final torrent = torrents.first;

      // Enable sequential download if not already enabled
      if (!torrent.sequentialDownload) {
        await toggleSequentialDownload(hash);
      }

      // Enable first/last piece priority if not already enabled
      if (!torrent.firstLastPiecePriority) {
        await toggleFirstLastPiecePrio(hash);
      }

      return true;
    } catch (e) {
      _log('Enable streaming mode error: $e');
      return false;
    }
  }

  /// Get piece states for a torrent (0=not downloaded, 1=downloading, 2=downloaded)
  Future<List<int>?> getPieceStates(String hash) async {
    if (!await _ensureAuthenticated()) return null;

    try {
      final response = await _dio.get(
        '/api/v2/torrents/pieceStates',
        queryParameters: {'hash': hash},
      );

      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List).cast<int>();
      }
      return null;
    } catch (e) {
      _log('Get piece states error: $e');
      return null;
    }
  }

  /// Check if beginning of torrent is ready for streaming (first 5% pieces downloaded)
  Future<bool> isReadyForStreaming(
    String hash, {
    double minProgress = 0.05,
  }) async {
    try {
      final pieceStates = await getPieceStates(hash);
      if (pieceStates == null || pieceStates.isEmpty) return false;

      // Calculate how many pieces we need at the start
      final minPieces = (pieceStates.length * minProgress).ceil().clamp(
        1,
        pieceStates.length,
      );

      // Check if the first N pieces are downloaded (state == 2)
      for (int i = 0; i < minPieces; i++) {
        if (pieceStates[i] != 2) return false;
      }

      return true;
    } catch (e) {
      _log('Check streaming ready error: $e');
      return false;
    }
  }

  /// Check whether the selected file has enough contiguous pieces at its own
  /// beginning to start playback.
  ///
  /// qBittorrent's `pieceStates` response is torrent-wide, while `files`
  /// exposes each file's inclusive `piece_range`. Streaming a season pack must
  /// check the selected episode's range, not piece 0 of the whole torrent.
  Future<bool> isFileReadyForStreaming(
    String hash,
    TorrentFile file, {
    double minProgress = 0.05,
    int? minBufferBytes,
  }) async {
    try {
      final pieceStates = await getPieceStates(hash);
      if (pieceStates == null || pieceStates.isEmpty) return false;

      final range = file.pieceRange;
      if (range == null || range.length < 2) {
        // Older qBittorrent versions may omit piece_range. Keep the previous
        // torrent-level behavior as a compatibility fallback.
        return isReadyForStreaming(hash, minProgress: minProgress);
      }

      return isPieceRangeReadyForStreaming(
        pieceStates: pieceStates,
        pieceRange: range,
        fileSizeBytes: file.size,
        minProgress: minProgress,
        minBufferBytes: minBufferBytes,
      );
    } catch (e) {
      _log('Check file streaming ready error: $e');
      return false;
    }
  }

  @visibleForTesting
  static bool isPieceRangeReadyForStreaming({
    required List<int> pieceStates,
    required List<int> pieceRange,
    required int fileSizeBytes,
    required double minProgress,
    int? minBufferBytes,
  }) {
    if (pieceStates.isEmpty || pieceRange.length < 2) return false;

    final start = pieceRange[0].clamp(0, pieceStates.length - 1).toInt();
    final end = pieceRange[1].clamp(0, pieceStates.length - 1).toInt();
    if (end < start) return false;

    final filePieceCount = end - start + 1;
    final requiredPieces = requiredContiguousPiecesForStreaming(
      filePieceCount: filePieceCount,
      fileSizeBytes: fileSizeBytes,
      minProgress: minProgress,
      minBufferBytes: minBufferBytes,
    );

    for (var i = start; i < start + requiredPieces; i++) {
      if (pieceStates[i] != 2) return false;
    }

    return true;
  }

  @visibleForTesting
  static int requiredContiguousPiecesForStreaming({
    required int filePieceCount,
    required int fileSizeBytes,
    required double minProgress,
    int? minBufferBytes,
  }) {
    if (filePieceCount <= 0) return 0;

    final progress = minProgress.clamp(0.0, 1.0);
    final byProgress = (filePieceCount * progress).ceil();
    final byBytes =
        minBufferBytes != null && minBufferBytes > 0 && fileSizeBytes > 0
        ? (filePieceCount * (minBufferBytes / fileSizeBytes)).ceil()
        : 0;

    return math.max(1, math.min(filePieceCount, math.max(byProgress, byBytes)));
  }

  /// Check connection to qBittorrent
  Future<bool> testConnection() async {
    try {
      final response = await _dio.get('/api/v2/app/version');
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Dispose resources
  void dispose() {
    _dio.close();
  }
}
