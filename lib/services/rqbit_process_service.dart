import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:process_run/process_run.dart';

import '../utils/constants.dart';
import '../utils/platform_utils.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';
import 'torrent_engine_process.dart';

/// Lifecycle for the bundled rqbit sidecar.
///
/// The contrast with `QBittorrentProcessService` is the point of the whole
/// exercise. That one launches a desktop application the user can see — a
/// window on Windows, a Dock and tray presence on macOS, its own completion
/// notifications on both. This launches a headless binary whose only
/// interface is the HTTP API on loopback: no window, no tray icon, no
/// notifications, no preferences dialog, and no login, because rqbit's API is
/// unauthenticated when it listens on 127.0.0.1.
///
/// From the user's side there is no second program at all.
class RqbitProcessService implements TorrentEngineProcess {
  /// The one sidecar this app has running, shared across instances.
  ///
  /// Static because the handle has to outlive the instance that opened it.
  /// This service is rebuilt whenever settings change — a new download folder,
  /// a new speed limit — and an instance-level handle would be dropped with
  /// the old instance, leaving nothing able to stop the process it started.
  /// There is only ever one sidecar, so one handle models it correctly.
  static Process? _spawned;
  late final PollLoop _healthCheck = PollLoop(
    name: 'rqbit-process-health',
    onTick: _performHealthCheck,
  );
  bool _isStarting = false;

  final int _port;
  final String _host;
  final String _downloadPath;
  final int _downloadLimitBytes;
  final int _uploadLimitBytes;

  /// Explicit binary path from settings. Empty means "find it".
  final String _configuredPath;

  final void Function(bool isConnected)? onConnectionStatusChanged;
  final void Function(String message)? onLog;

  RqbitProcessService({
    String configuredPath = '',
    int port = AppConstants.defaultRqbitPort,
    String host = AppConstants.rqbitHost,
    required String downloadPath,
    int downloadLimitBytes = 0,
    int uploadLimitBytes = 0,
    this.onConnectionStatusChanged,
    this.onLog,
  }) : _configuredPath = configuredPath,
       _port = port,
       _host = host,
       _downloadPath = downloadPath,
       _downloadLimitBytes = downloadLimitBytes,
       _uploadLimitBytes = uploadLimitBytes;

  @override
  bool get managesLocalProcess => PlatformUtils.isLocalHost(_host);

  @override
  Future<bool> isRunning() => PlatformUtils.isPortInUse(_port, host: _host);

  /// Where the sidecar lives once it is bundled: beside the app executable.
  ///
  /// That is `MyApp.app/Contents/MacOS/` on macOS and the install directory on
  /// Windows and Linux — the same folder Flutter's own runner sits in, which
  /// is the one place guaranteed to exist in every packaging channel
  /// (portable zip, MSIX, .app).
  static String bundledPath() {
    final name = Platform.isWindows ? 'rqbit.exe' : 'rqbit';
    return p.join(p.dirname(Platform.resolvedExecutable), name);
  }

  /// Where the engine keeps its session state.
  ///
  /// Under the app's own support directory rather than rqbit's OS default, so
  /// an uninstall takes it along and a user's own rqbit — if they run one —
  /// never shares a session with ours. `getApplicationSupportDirectory` is
  /// what the rest of the app already uses, and it is the only thing that
  /// resolves correctly inside the MSIX container.
  static Future<String> statePath() async {
    final dir = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'engine'),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Locate the engine: the configured override, then the bundled copy, then
  /// whatever is on `PATH` (which is how a developer runs it before Phase 4
  /// vendors the binaries).
  Future<String?> findExecutable() async {
    if (_configuredPath.isNotEmpty && await File(_configuredPath).exists()) {
      return _configuredPath;
    }

    final bundled = bundledPath();
    if (await File(bundled).exists()) return bundled;

    try {
      final onPath = whichSync('rqbit');
      if (onPath != null) return onPath;
    } catch (e) {
      _log('Error looking for rqbit on PATH: $e');
    }
    return null;
  }

  /// Command line for the sidecar.
  ///
  /// Pure and static so the argument order — global flags before the
  /// subcommand, which clap requires and which is easy to get wrong — is
  /// covered by a test rather than by running it.
  static List<String> buildArguments({
    required String host,
    required int port,
    required String downloadPath,
    required String persistencePath,
    int downloadLimitBytes = 0,
    int uploadLimitBytes = 0,
  }) {
    return [
      // Global options first; `server` is a subcommand and clap will not
      // accept these after it.
      '--http-api-listen-addr', '$host:$port',
      // We are a desktop client on someone's home connection, not a seedbox.
      // Port-forwarding attempts are noise and can hang startup on routers
      // that answer UPnP slowly.
      '--disable-upnp-port-forward',
      if (downloadLimitBytes > 0) ...[
        '--ratelimit-download',
        '$downloadLimitBytes',
      ],
      if (uploadLimitBytes > 0) ...['--ratelimit-upload', '$uploadLimitBytes'],
      'server', 'start',
      // Keep session state inside the app's own data directory rather than
      // rqbit's OS default, so an uninstall takes it with us and a user's own
      // rqbit (if they run one) never shares a session with ours.
      '--persistence-location', persistencePath,
      // NB: deliberately no `--fastresume`. It skips checksumming on restart,
      // which would be welcome, but rqbit still marks it experimental and a
      // wrong resume surfaces as corrupt video rather than as an error.
      downloadPath,
    ];
  }

  @override
  Future<bool> start() async {
    if (_isStarting) {
      _log('Already starting rqbit...');
      return false;
    }

    if (!managesLocalProcess) {
      _log('rqbit is remote ($_host) — not starting a local process');
      return isRunning();
    }

    _isStarting = true;
    try {
      if (await isRunning()) {
        _log('rqbit is already listening on port $_port');
        onConnectionStatusChanged?.call(true);
        _startHealthCheck();
        return true;
      }

      final executable = await findExecutable();
      if (executable == null) {
        _log('rqbit executable not found (bundled, configured or on PATH)');
        return false;
      }

      final persistence = await statePath();
      final args = buildArguments(
        host: _host,
        port: _port,
        downloadPath: _downloadPath,
        persistencePath: persistence,
        downloadLimitBytes: _downloadLimitBytes,
        uploadLimitBytes: _uploadLimitBytes,
      );

      _log('Starting rqbit: $executable ${args.join(' ')}');
      _spawned = await Process.start(
        executable,
        args,
        // Detached: no console window on Windows, and the sidecar is not tied
        // to this Dart isolate's stdio.
        mode: ProcessStartMode.detached,
      );
      _log('rqbit started with PID: ${_spawned?.pid}');

      final ready = await _waitForReady();
      if (ready) {
        _log('rqbit is ready');
        onConnectionStatusChanged?.call(true);
        _startHealthCheck();
      } else {
        _log('rqbit failed to become ready');
        onConnectionStatusChanged?.call(false);
      }
      return ready;
    } catch (e) {
      _log('Error starting rqbit: $e');
      return false;
    } finally {
      _isStarting = false;
    }
  }

  Future<bool> _waitForReady({
    int maxAttempts = AppConstants.maxRetryAttempts,
    Duration initialDelay = AppConstants.initialRetryDelay,
  }) async {
    var delay = initialDelay;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await Future.delayed(delay);
      if (await isRunning()) return true;
      delay = Duration(
        milliseconds:
            (delay.inMilliseconds * AppConstants.retryBackoffMultiplier)
                .round(),
      );
    }
    return false;
  }

  void _startHealthCheck() {
    _healthCheck.start(AppConstants.connectionCheckInterval);
  }

  Future<void> _performHealthCheck() async {
    if (await isRunning()) return;
    _log('rqbit health check failed — not running');
    onConnectionStatusChanged?.call(false);
    if (!managesLocalProcess) return;
    _log('Attempting to restart rqbit...');
    await start();
  }

  /// Shut the sidecar down.
  ///
  /// Only ever kills a process *we* started: [_spawned] is null when the user
  /// is pointed at an engine they run themselves, and taking that one down
  /// would be well outside our remit.
  @override
  Future<void> stop() async {
    _healthCheck.stop();
    final process = _spawned;
    if (process != null) {
      _log('Stopping rqbit (PID ${process.pid})...');
      _spawned = null;
      process.kill(ProcessSignal.sigterm);
    }
    onConnectionStatusChanged?.call(false);
  }

  /// Stops the health check but leaves the process running.
  ///
  /// This service is rebuilt on every settings change, and killing the engine
  /// each time would interrupt whatever is streaming. The sidecar is shut
  /// down with the app — by `main`'s close handler calling [stop] — not with
  /// the provider. That handler is the reason [_spawned] is static: by the
  /// time it runs, the instance that started the process is long gone.
  @override
  void dispose() {
    _healthCheck.dispose();
  }

  void _log(String message) {
    AppLog.d('[RqbitProcess] $message');
    onLog?.call(message);
  }
}
