import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:process_run/process_run.dart';

import '../utils/constants.dart';
import '../utils/platform_utils.dart';
import 'app_logger.dart';
import 'engine_process_support.dart';
import 'torrent_engine_process.dart';

/// Service for managing the qBittorrent process lifecycle.
///
/// Note what it launches on each platform, because it is the thing the
/// built-in engine exists to avoid: on Windows this is `qbittorrent.exe`, the
/// *desktop* application — window, tray icon and its own notifications. On
/// macOS `open -gj` hides it at launch, but it is still the GUI app. Only
/// Linux gets a genuinely headless binary (`qbittorrent-nox`).
///
/// ## Stopping it
///
/// One policy on every platform: a qBittorrent this app launched is asked to
/// quit through its own Web API when the app closes — the same clean exit as
/// its File → Exit, resume data saved — and one the user started is never
/// touched. There used to be three behaviours: Windows hard-killed it
/// (TerminateProcess, so no resume data), macOS did nothing (the PID it held
/// was `open`'s, long exited), and Windows only even tried while no setting
/// had changed since the launch.
class QBittorrentProcessService extends EngineProcessSupport {
  QBittorrentProcessService({
    String? qbittorrentPath,
    super.port = AppConstants.defaultPort,
    super.host = AppConstants.defaultHost,
    Future<bool> Function()? requestQuit,
  }) : _qbittorrentPath =
           qbittorrentPath ?? PlatformUtils.getDefaultQBittorrentPath(),
       _requestQuit = requestQuit,
       super(engineName: 'qBittorrent', logTag: 'QBittorrentProcess');

  /// Not final: [launch] rewrites it when [findExecutable] locates
  /// qBittorrent somewhere other than the configured path.
  String _qbittorrentPath;

  /// Asks the running qBittorrent to quit through its Web API. Supplied by
  /// whoever builds this service, which is what holds the credentials.
  final Future<bool> Function()? _requestQuit;

  /// Set when the app starts closing, and never cleared — see
  /// [EngineProcessSupport.isClosing].
  static bool _closing = false;

  /// How to ask the qBittorrent this app launched to quit, or null when the
  /// app launched none. Static: the instance that launched it may have been
  /// replaced — or the user may have switched engines — by the time the app
  /// closes.
  static Future<bool> Function()? _quitLaunched;

  @override
  bool get isClosing => _closing;

  /// Whether this run of the app launched a qBittorrent.
  @visibleForTesting
  static bool get launchedThisSession => _quitLaunched != null;

  @visibleForTesting
  static void resetForTest() {
    _closing = false;
    _quitLaunched = null;
  }

  /// Check if the qBittorrent executable exists
  Future<bool> executableExists() =>
      PlatformUtils.qBittorrentExists(_qbittorrentPath);

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
          debug('Found qBittorrent at: $result');
          return result;
        }
      }

      for (final candidate in PlatformUtils.qBittorrentCandidates()) {
        if (await PlatformUtils.qBittorrentExists(candidate)) {
          debug('Found qBittorrent at: $candidate');
          return candidate;
        }
      }
    } catch (e) {
      log('Error finding qBittorrent: $e');
    }
    return null;
  }

  @override
  Future<bool> launch() async {
    if (!managesLocalProcess) {
      log('qBittorrent is remote ($host) — not starting a local process');
      return isRunning();
    }

    if (await isRunning()) {
      log('qBittorrent is already running on port $port');
      return true;
    }

    if (!await executableExists()) {
      final found = await findExecutable();
      if (found == null) {
        log('qBittorrent executable not found at: $_qbittorrentPath');
        return failWith(EngineStartFailure.notFound);
      }
      _qbittorrentPath = found;
    }
    if (isClosing || isDisposed) return failWith(EngineStartFailure.closing);

    log('Starting qBittorrent from: $_qbittorrentPath');
    if (Platform.isMacOS && _qbittorrentPath.contains('.app/')) {
      // `open -gj` launches the bundle hidden and in the background. The
      // process it returns is `open`'s, which exits at once — which is why
      // stopping goes through the Web API rather than a PID.
      final appPath = _qbittorrentPath.substring(
        0,
        _qbittorrentPath.indexOf('.app/') + '.app'.length,
      );
      await Process.start('open', [
        '-g', // Don't bring to foreground
        '-j', // Launch hidden
        appPath,
        '--args',
        '--webui-port=$port',
      ], mode: ProcessStartMode.detached);
    } else {
      await Process.start(_qbittorrentPath, [
        '--webui-port=$port',
      ], mode: ProcessStartMode.detached);
    }

    // Recorded at launch, not at readiness: one that takes too long to
    // answer is still ours to close.
    _quitLaunched = _requestQuit;

    final ready = await waitForReady();
    log(ready ? 'qBittorrent is ready' : 'qBittorrent failed to start');
    return ready;
  }

  /// Ask a qBittorrent this app launched to quit; leave anything else alone.
  ///
  /// [closing] makes it final for this run of the app: no service may launch
  /// one again, which is what stops a health check that was already in
  /// flight from relaunching it moments after it was asked to go.
  static Future<void> quitIfLaunched({bool closing = false}) async {
    if (closing) _closing = true;
    final quit = _quitLaunched;
    if (quit == null) return;
    _quitLaunched = null;
    AppLog.i('[QBittorrentProcess] asking the qBittorrent we launched to quit');
    try {
      final ok = await quit();
      AppLog.i(
        '[QBittorrentProcess] ${ok ? 'qBittorrent is quitting' : 'qBittorrent did not accept the request to quit'}',
      );
    } catch (e) {
      AppLog.w('[QBittorrentProcess] could not ask qBittorrent to quit: $e');
    }
  }

  /// Stop checking on qBittorrent. It keeps running: it is the user's
  /// desktop application, and whether it closes with this app is decided once,
  /// at shutdown, by [quitIfLaunched].
  @override
  Future<void> stop() async => stopKeepingAlive();
}
