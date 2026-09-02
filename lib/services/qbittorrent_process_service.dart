import 'dart:async';
import 'dart:io';

import 'package:process_run/process_run.dart';

import '../utils/constants.dart';
import '../utils/platform_utils.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';

/// Service for managing the qBittorrent process lifecycle
class QBittorrentProcessService {
  Process? _process;
  late final PollLoop _healthCheck = PollLoop(
    name: 'qb-process-health',
    onTick: _performHealthCheck,
  );
  bool _isStarting = false;

  /// Not final: [start] rewrites it when [findExecutable] locates qBittorrent
  /// somewhere other than the configured path.
  String _qbittorrentPath;
  final int _port;
  final String _host;

  /// Callback for when connection status changes
  final void Function(bool isConnected)? onConnectionStatusChanged;

  /// Callback for logging
  final void Function(String message)? onLog;

  QBittorrentProcessService({
    String? qbittorrentPath,
    int port = AppConstants.defaultPort,
    String host = AppConstants.defaultHost,
    this.onConnectionStatusChanged,
    this.onLog,
  }) : _qbittorrentPath =
           qbittorrentPath ?? PlatformUtils.getDefaultQBittorrentPath(),
       _port = port,
       _host = host;

  /// Whether this service may start and restart a qBittorrent process.
  ///
  /// False when the user has pointed the app at another machine: we cannot
  /// launch a process there, and probing our own loopback port to decide
  /// would answer "not running" forever — which had the health check trying
  /// to spawn a local qBittorrent every 5 s against a perfectly healthy
  /// remote one.
  bool get managesLocalProcess => PlatformUtils.isLocalHost(_host);

  // No setters: a settings change rebuilds this service through
  // `qbProcessServiceProvider`.

  /// Check if qBittorrent is currently running (by checking if port is in use)
  Future<bool> isRunning() async {
    return PlatformUtils.isPortInUse(_port, host: _host);
  }

  /// Check if the qBittorrent executable exists
  Future<bool> executableExists() async {
    return PlatformUtils.qBittorrentExists(_qbittorrentPath);
  }

  /// Find the qBittorrent executable.
  ///
  /// `which` is enough on macOS and Linux, where installers put qBittorrent
  /// on `PATH`. Nothing does that on Windows, so `which` there always
  /// answers null and the search has to be a list of known install
  /// locations — 32-bit, per-user, and scoop layouts included. Without them
  /// anyone who did not install to the default 64-bit path met
  /// "qBittorrent executable not found" with no hint that the fix was to
  /// type a path into Settings.
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

      for (final candidate in PlatformUtils.qBittorrentCandidates()) {
        if (await PlatformUtils.qBittorrentExists(candidate)) {
          _log('Found qBittorrent at: $candidate');
          return candidate;
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

    if (!managesLocalProcess) {
      _log('qBittorrent is remote ($_host) — not starting a local process');
      _isStarting = false;
      return isRunning();
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
    _healthCheck.start(AppConstants.connectionCheckInterval);
  }

  /// Perform a health check
  Future<void> _performHealthCheck() async {
    final running = await isRunning();
    if (running) return;

    _log('qBittorrent health check failed - not running');
    onConnectionStatusChanged?.call(false);

    if (!managesLocalProcess) return;

    // Try to restart
    _log('Attempting to restart qBittorrent...');
    await start();
  }

  /// Stop qBittorrent process
  Future<void> stop() async {
    _healthCheck.stop();

    if (_process != null) {
      _log('Stopping qBittorrent process...');
      _process?.kill(ProcessSignal.sigterm);
      _process = null;
    }

    onConnectionStatusChanged?.call(false);
  }

  /// Dispose of resources
  void dispose() {
    _healthCheck.dispose();
    // Note: We don't kill the process on dispose as qBittorrent should keep running
  }

  /// Log a message. The tag is applied here rather than at the [onLog]
  /// adapter, so a line is tagged exactly once.
  void _log(String message) {
    AppLog.d('[QBittorrentProcess] $message');
    onLog?.call(message);
  }
}
