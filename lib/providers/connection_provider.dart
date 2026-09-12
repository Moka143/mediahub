import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_logger.dart';
import '../services/qbittorrent_api_service.dart';
import '../services/qbittorrent_process_service.dart';
import '../services/rqbit_engine.dart';
import '../services/rqbit_process_service.dart';
import '../services/torrent_engine.dart';
import '../services/torrent_engine_process.dart';
import '../utils/constants.dart';
import '../utils/poll_loop.dart';
import 'settings_provider.dart';

/// Connection status enum
enum ConnectionStatus { disconnected, connecting, connected, error }

/// Connection state class
class ConnectionState {
  final ConnectionStatus status;
  final String? errorMessage;
  final String? qbVersion;
  final String? apiVersion;

  const ConnectionState({
    this.status = ConnectionStatus.disconnected,
    this.errorMessage,
    this.qbVersion,
    this.apiVersion,
  });

  ConnectionState copyWith({
    ConnectionStatus? status,
    String? errorMessage,
    String? qbVersion,
    String? apiVersion,
  }) {
    return ConnectionState(
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      qbVersion: qbVersion ?? this.qbVersion,
      apiVersion: apiVersion ?? this.apiVersion,
    );
  }

  bool get isConnected => status == ConnectionStatus.connected;
  bool get isConnecting => status == ConnectionStatus.connecting;
  bool get hasError => status == ConnectionStatus.error;
}

/// The engine process, chosen by the same setting as [torrentEngineProvider].
///
/// The two must agree: an engine pointed at a port nothing is listening on
/// reconnects forever, and a process started for a backend nobody is talking
/// to is a stray daemon. Both read `settings.engineKind`, and both are rebuilt
/// together when it changes.
final engineProcessProvider = Provider<TorrentEngineProcess>((ref) {
  final settings = ref.watch(settingsProvider);

  // The service already writes tagged lines to AppLog; the callback only feeds
  // the in-app connection log, so it must not log again.
  final service = switch (settings.engineKind) {
    TorrentEngineKind.builtin => RqbitProcessService(
      configuredPath: settings.rqbitPath,
      port: settings.rqbitPort,
      downloadPath: settings.defaultSavePath,
      downloadLimitBytes: settings.downloadSpeedLimit,
      uploadLimitBytes: settings.uploadSpeedLimit,
      onLog: (_) {},
    ),
    TorrentEngineKind.qbittorrent => QBittorrentProcessService(
      qbittorrentPath: settings.qbittorrentPath,
      port: settings.port,
      host: settings.host,
      onLog: (_) {},
    ),
  };

  ref.onDispose(service.dispose);
  return service;
});

/// The torrent backend the whole app talks to.
///
/// Typed as [TorrentEngine], not as the concrete service: this is the single
/// place the backend is chosen, so swapping it is a change here and nowhere
/// else. Rebuilt whenever settings change, which is why neither the engine nor
/// the process service has setters.
final torrentEngineProvider = Provider<TorrentEngine>((ref) {
  final settings = ref.watch(settingsProvider);

  final service = switch (settings.engineKind) {
    TorrentEngineKind.builtin => RqbitEngine(
      port: settings.rqbitPort,
      defaultSavePath: settings.defaultSavePath,
      onLog: (_) {},
    ),
    TorrentEngineKind.qbittorrent => QBittorrentApiService(
      host: settings.host,
      port: settings.port,
      username: settings.username,
      password: settings.password,
      onLog: (_) {},
    ),
  };

  ref.onDispose(() => service.dispose());

  return service;
});

/// Provider for connection state
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(
      ConnectionNotifier.new,
    );

/// Notifier for managing connection state
class ConnectionNotifier extends Notifier<ConnectionState> {
  late final PollLoop _connectionCheck = PollLoop(
    name: 'connection',
    onTick: _checkConnection,
  );

  @override
  ConnectionState build() {
    // Clean up timer on dispose
    ref.onDispose(_connectionCheck.dispose);

    // Schedule initialization
    Future.microtask(() => _initialize());

    return const ConnectionState();
  }

  TorrentEngineProcess get _processService => ref.read(engineProcessProvider);
  TorrentEngine get _apiService => ref.read(torrentEngineProvider);
  bool get _autoStart => ref.read(settingsProvider).autoStartQBittorrent;

  /// Initialize connection
  Future<void> _initialize() async {
    if (_autoStart) {
      await connect();
    } else {
      // Just try to connect without starting process
      await _tryConnect();
    }
  }

  /// Connect to qBittorrent (start if needed)
  Future<bool> connect() async {
    state = state.copyWith(status: ConnectionStatus.connecting);

    try {
      // Check if already running
      final isRunning = await _processService.isRunning();

      // Only attempt a launch for a qBittorrent we could actually launch.
      // A remote host is somebody else's process.
      if (!isRunning && _autoStart && _processService.managesLocalProcess) {
        // Try to start qBittorrent
        final started = await _processService.start();
        if (!started) {
          state = state.copyWith(
            status: ConnectionStatus.error,
            errorMessage: 'Failed to start the torrent engine',
          );
          return false;
        }
      }

      // Try to login
      return await _tryConnect();
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  /// Try to connect to qBittorrent API
  Future<bool> _tryConnect() async {
    state = state.copyWith(status: ConnectionStatus.connecting);

    try {
      // Try to login
      final loggedIn = await _apiService.login();

      if (loggedIn) {
        // Get version info
        final version = await _apiService.getVersion();
        final apiVersion = await _apiService.getApiVersion();

        state = ConnectionState(
          status: ConnectionStatus.connected,
          qbVersion: version,
          apiVersion: apiVersion,
        );

        // Sync speed limits from settings to qBittorrent
        await _syncSpeedLimits();

        _startConnectionCheck();
        return true;
      } else {
        state = state.copyWith(
          status: ConnectionStatus.error,
          errorMessage:
              'Failed to authenticate. Check username/password in Settings.',
        );
        return false;
      }
    } on DioException catch (e) {
      String errorMsg;
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
          errorMsg = 'Connection timeout. Is qBittorrent running?';
        case DioExceptionType.connectionError:
          errorMsg =
              'Cannot connect to ${_apiService.baseUrl}. Is qBittorrent Web UI enabled?';
        case DioExceptionType.receiveTimeout:
          errorMsg = 'Server not responding';
        default:
          errorMsg = e.message ?? 'Connection failed';
      }
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: errorMsg,
      );
      return false;
    } catch (e) {
      state = state.copyWith(
        status: ConnectionStatus.error,
        errorMessage: e.toString(),
      );
      return false;
    }
  }

  /// Start periodic connection check
  void _startConnectionCheck() {
    _connectionCheck.start(const Duration(seconds: 30));
  }

  /// Sync speed limits from settings to qBittorrent
  Future<void> _syncSpeedLimits() async {
    try {
      final settings = ref.read(settingsProvider);

      // Only sync if limits are set (non-zero)
      if (settings.downloadSpeedLimit > 0) {
        await _apiService.setDownloadLimit(settings.downloadSpeedLimit);
        AppLog.d(
          '[Connection] Synced download limit: ${settings.downloadSpeedLimit ~/ 1024} KB/s',
        );
      }

      if (settings.uploadSpeedLimit > 0) {
        await _apiService.setUploadLimit(settings.uploadSpeedLimit);
        AppLog.d(
          '[Connection] Synced upload limit: ${settings.uploadSpeedLimit ~/ 1024} KB/s',
        );
      }
    } catch (e) {
      AppLog.e('[Connection] Failed to sync speed limits: $e');
    }
  }

  /// Check connection status
  Future<void> _checkConnection() async {
    if (state.status != ConnectionStatus.connected) return;

    final connected = await _apiService.testConnection();
    if (!connected) {
      state = state.copyWith(
        status: ConnectionStatus.disconnected,
        errorMessage: 'Connection lost',
      );
      _connectionCheck.stop();
    }
  }

  /// Disconnect from qBittorrent
  Future<void> disconnect() async {
    _connectionCheck.stop();
    await _apiService.logout();
    state = const ConnectionState(status: ConnectionStatus.disconnected);
  }

  /// Retry connection
  Future<bool> retry() async {
    return connect();
  }
}
