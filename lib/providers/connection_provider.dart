import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/qbittorrent_api_service.dart';
import '../services/qbittorrent_process_service.dart';
import 'settings_provider.dart';

/// Connection status enum
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

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

/// Provider for qBittorrent process service
final qbProcessServiceProvider = Provider<QBittorrentProcessService>((ref) {
  final settings = ref.watch(settingsProvider);

  return QBittorrentProcessService(
    qbittorrentPath: settings.qbittorrentPath,
    port: settings.port,
    onLog: (message) => debugPrint('[ProcessService] $message'),
  );
});

/// Provider for qBittorrent API service
final qbApiServiceProvider = Provider<QBittorrentApiService>((ref) {
  final settings = ref.watch(settingsProvider);

  final service = QBittorrentApiService(
    host: settings.host,
    port: settings.port,
    username: settings.username,
    password: settings.password,
    onLog: (message) => debugPrint('[APIService] $message'),
  );

  ref.onDispose(() => service.dispose());

  return service;
});

/// Provider for connection state
final connectionProvider = NotifierProvider<ConnectionNotifier, ConnectionState>(
  ConnectionNotifier.new,
);

/// Notifier for managing connection state
class ConnectionNotifier extends Notifier<ConnectionState> {
  Timer? _connectionCheckTimer;

  @override
  ConnectionState build() {
    // Clean up timer on dispose
    ref.onDispose(() {
      _connectionCheckTimer?.cancel();
    });

    // Schedule initialization
    Future.microtask(() => _initialize());

    return const ConnectionState();
  }

  QBittorrentProcessService get _processService => ref.read(qbProcessServiceProvider);
  QBittorrentApiService get _apiService => ref.read(qbApiServiceProvider);
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

      if (!isRunning && _autoStart) {
        // Try to start qBittorrent
        final started = await _processService.start();
        if (!started) {
          state = state.copyWith(
            status: ConnectionStatus.error,
            errorMessage: 'Failed to start qBittorrent',
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
          errorMessage: 'Failed to authenticate. Check username/password in Settings.',
        );
        return false;
      }
    } on DioException catch (e) {
      String errorMsg;
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
          errorMsg = 'Connection timeout. Is qBittorrent running?';
        case DioExceptionType.connectionError:
          errorMsg = 'Cannot connect to ${_apiService.baseUrl}. Is qBittorrent Web UI enabled?';
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
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkConnection(),
    );
  }

  /// Sync speed limits from settings to qBittorrent
  Future<void> _syncSpeedLimits() async {
    try {
      final settings = ref.read(settingsProvider);
      
      // Only sync if limits are set (non-zero)
      if (settings.downloadSpeedLimit > 0) {
        await _apiService.setDownloadLimit(settings.downloadSpeedLimit);
        debugPrint('[Connection] Synced download limit: ${settings.downloadSpeedLimit ~/ 1024} KB/s');
      }
      
      if (settings.uploadSpeedLimit > 0) {
        await _apiService.setUploadLimit(settings.uploadSpeedLimit);
        debugPrint('[Connection] Synced upload limit: ${settings.uploadSpeedLimit ~/ 1024} KB/s');
      }
    } catch (e) {
      debugPrint('[Connection] Failed to sync speed limits: $e');
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
      _connectionCheckTimer?.cancel();
    }
  }

  /// Disconnect from qBittorrent
  Future<void> disconnect() async {
    _connectionCheckTimer?.cancel();
    await _apiService.logout();
    state = const ConnectionState(status: ConnectionStatus.disconnected);
  }

  /// Retry connection
  Future<bool> retry() async {
    return await connect();
  }
}
