import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:process_run/process_run.dart';

import '../utils/constants.dart';
import '../utils/platform_utils.dart';

/// Service for managing the qBittorrent process lifecycle
class QBittorrentProcessService {
  Process? _process;
  Timer? _healthCheckTimer;
  bool _isStarting = false;
  String _qbittorrentPath;
  int _port;

  /// Callback for when connection status changes
  final void Function(bool isConnected)? onConnectionStatusChanged;

  /// Callback for logging
  final void Function(String message)? onLog;

  QBittorrentProcessService({
    String? qbittorrentPath,
    int port = AppConstants.defaultPort,
    this.onConnectionStatusChanged,
    this.onLog,
  }) : _qbittorrentPath =
           qbittorrentPath ?? PlatformUtils.getDefaultQBittorrentPath(),
       _port = port;

  /// Update the qBittorrent path
  void setQBittorrentPath(String path) {
    _qbittorrentPath = path;
  }

  /// Update the port
  void setPort(int port) {
    _port = port;
  }

  /// Check if qBittorrent is currently running (by checking if port is in use)
  Future<bool> isRunning() async {
    return PlatformUtils.isPortInUse(_port);
  }

  /// Check if the qBittorrent executable exists
  Future<bool> executableExists() async {
    return PlatformUtils.qBittorrentExists(_qbittorrentPath);
  }

  /// Find qBittorrent executable using 'which' command
  Future<String?> findExecutable() async {
    try {
      final names = Platform.isLinux
          ? ['qbittorrent-nox', 'qbittorrent']
          : ['qbittorrent'];

      for (final name in names) {
        final result = whichSync(name);
        if (result != null) {
          _log('Found qBittorrent at: $result');
          return result;
        }
      }
    } catch (e) {
      _log('Error finding qBittorrent: $e');
    }
    return null;
  }

  /// Start qBittorrent process
  Future<bool> start() async {
    if (_isStarting) {
      _log('Already starting qBittorrent...');
      return false;
    }

    _isStarting = true;

    try {
      // Check if already running
      if (await isRunning()) {
        _log('qBittorrent is already running on port $_port');
        _isStarting = false;
        onConnectionStatusChanged?.call(true);
        _startHealthCheck();
        return true;
      }

      // Check if executable exists
      if (!await executableExists()) {
        // Try to find it
        final found = await findExecutable();
        if (found != null) {
          _qbittorrentPath = found;
        } else {
          _log('qBittorrent executable not found at: $_qbittorrentPath');
          _isStarting = false;
          return false;
        }
      }

      _log('Starting qBittorrent from: $_qbittorrentPath');

      // On macOS, use `open -gj` to launch the app hidden and in the background
      if (Platform.isMacOS && _qbittorrentPath.contains('.app/')) {
        // Extract the .app bundle path from the binary path
        final appPath = _qbittorrentPath.substring(
          0,
          _qbittorrentPath.indexOf('.app/') + '.app'.length,
        );
        final args = <String>[
          '-g', // Don't bring to foreground
          '-j', // Launch hidden
          appPath,
          '--args',
          '--webui-port=$_port',
        ];
        _process = await Process.start(
          'open',
          args,
          mode: ProcessStartMode.detached,
        );
      } else {
        // Build arguments
        final args = _buildArguments();

        // Start the process
        _process = await Process.start(
          _qbittorrentPath,
          args,
          mode: ProcessStartMode.detached,
        );
      }

      _log('qBittorrent process started with PID: ${_process?.pid}');

      // Wait for qBittorrent to be ready
      final ready = await _waitForReady();
      if (ready) {
        _log('qBittorrent is ready');
        onConnectionStatusChanged?.call(true);
        _startHealthCheck();
      } else {
        _log('qBittorrent failed to start');
        onConnectionStatusChanged?.call(false);
      }

      _isStarting = false;
      return ready;
    } catch (e) {
      _log('Error starting qBittorrent: $e');
      _isStarting = false;
      return false;
    }
  }

  /// Build command line arguments based on platform
  List<String> _buildArguments() {
    final args = <String>[];

    if (Platform.isMacOS) {
      // macOS doesn't need special args if Web UI is enabled in preferences
      args.add('--webui-port=$_port');
    } else if (Platform.isWindows) {
      args.add('--webui-port=$_port');
    } else if (Platform.isLinux) {
      // qbittorrent-nox is already a daemon, just specify port
      args.add('--webui-port=$_port');
    }

    return args;
  }

  /// Wait for qBittorrent to be ready (with retry logic)
  Future<bool> _waitForReady({
    int maxAttempts = AppConstants.maxRetryAttempts,
    Duration initialDelay = AppConstants.initialRetryDelay,
  }) async {
    var delay = initialDelay;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      _log('Waiting for qBittorrent... (attempt $attempt/$maxAttempts)');

      await Future.delayed(delay);

      if (await isRunning()) {
        return true;
      }

      // Exponential backoff
      delay = Duration(
        milliseconds:
            (delay.inMilliseconds * AppConstants.retryBackoffMultiplier)
                .round(),
      );
    }

    return false;
  }

  /// Start health check timer
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(
      AppConstants.connectionCheckInterval,
      (_) => _performHealthCheck(),
    );
  }

  /// Perform a health check
  Future<void> _performHealthCheck() async {
    final running = await isRunning();
    if (!running) {
      _log('qBittorrent health check failed - not running');
      onConnectionStatusChanged?.call(false);

      // Try to restart
      _log('Attempting to restart qBittorrent...');
      await start();
    }
  }

  /// Stop qBittorrent process
  Future<void> stop() async {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;

    if (_process != null) {
      _log('Stopping qBittorrent process...');
      _process?.kill(ProcessSignal.sigterm);
      _process = null;
    }

    onConnectionStatusChanged?.call(false);
  }

  /// Dispose of resources
  void dispose() {
    _healthCheckTimer?.cancel();
    // Note: We don't kill the process on dispose as qBittorrent should keep running
  }

  /// Log a message
  void _log(String message) {
    if (kDebugMode) {
      print('[QBittorrentProcess] $message');
    }
    onLog?.call(message);
  }
}
