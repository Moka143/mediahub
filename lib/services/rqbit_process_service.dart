import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:process_run/process_run.dart';

import '../utils/constants.dart';
import 'app_logger.dart';
import 'engine_pid_file.dart';
import 'engine_process_support.dart';
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
/// From the user's side there is no second program at all — which is exactly
/// why one left running after the app has gone is a bug: nothing on screen
/// says it is there.
///
/// ## Ownership
///
/// The sidecar is launched detached, so it does not die with the app; this
/// class is what stops it. The app owns at most one, recorded in [_owned]
/// (static: the service instance is rebuilt when its settings change, and the
/// record must survive that) and on disk in `rqbit.pid`, so a launch after a
/// crash can recognise the one the crash left behind. A process is only ever
/// stopped when that record proves this app started it.
class RqbitProcessService extends EngineProcessSupport {
  RqbitProcessService({
    super.port = AppConstants.defaultRqbitPort,
    required String downloadPath,
    int downloadLimitBytes = 0,
    int uploadLimitBytes = 0,
  }) : _downloadPath = downloadPath,
       _downloadLimitBytes = downloadLimitBytes,
       _uploadLimitBytes = uploadLimitBytes,
       super(
         engineName: 'rqbit',
         logTag: 'RqbitProcess',
         host: AppConstants.rqbitHost,
       );

  final String _downloadPath;
  int _downloadLimitBytes;
  int _uploadLimitBytes;

  /// The sidecar this app is responsible for, if any.
  static EngineLaunchRecord? _owned;

  /// Set when the app starts closing, and never cleared: an engine started
  /// after that would outlive the app with nothing left to stop it.
  static bool _closing = false;

  /// Launches and stops run one at a time, app-wide. Two service instances
  /// exist briefly whenever settings change, and two overlapping launches
  /// would both spawn a sidecar.
  static Future<void> _serial = Future<void>.value();

  /// How a process is looked up and signalled. Replaced in tests.
  @visibleForTesting
  static EngineProcessProbe probe = const SystemEngineProcessProbe();

  /// Where the launch record lives. Replaced in tests.
  @visibleForTesting
  static Future<EnginePidFile> Function() pidFileLocator = _defaultPidFile;

  /// How long a stopped sidecar gets to exit on its own before it is killed.
  static const Duration terminateGrace = Duration(milliseconds: 1500);

  @visibleForTesting
  static void resetForTest() {
    _owned = null;
    _closing = false;
    _serial = Future<void>.value();
    probe = const SystemEngineProcessProbe();
    pidFileLocator = _defaultPidFile;
  }

  @override
  bool get isClosing => _closing;

  /// Rate limits for the next launch.
  ///
  /// rqbit takes them as launch flags, and the settings screen promises they
  /// apply "when it next starts" — so a change is held here rather than
  /// restarting an engine that may be mid-stream.
  void setLaunchLimits({required int downloadBytes, required int uploadBytes}) {
    _downloadLimitBytes = downloadBytes;
    _uploadLimitBytes = uploadBytes;
  }

  static Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _serial.then((_) => body());
    _serial = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Where the sidecar lives once it is bundled: beside the app executable.
  ///
  /// That is `MyApp.app/Contents/MacOS/` on macOS and the install directory on
  /// Windows and Linux — the same folder Flutter's own runner sits in, which
  /// is the one place guaranteed to exist in every packaging channel
  /// (the Windows installer, MSIX, .app).
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

  static Future<EnginePidFile> _defaultPidFile() async =>
      EnginePidFile(p.join(await statePath(), 'rqbit.pid'));

  /// Locate the engine: the bundled copy, then whatever is on `PATH` (which is
  /// how a developer runs a debug build, where nothing is bundled).
  Future<String?> findExecutable() async {
    final bundled = bundledPath();
    if (await File(bundled).exists()) return bundled;

    try {
      final onPath = whichSync('rqbit');
      if (onPath != null) return onPath;
    } catch (e) {
      log('Error looking for rqbit on PATH: $e');
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

  EngineLaunchRecord _wanted(String executable, {int pid = 0}) =>
      EngineLaunchRecord(
        pid: pid,
        executable: executable,
        port: port,
        downloadPath: _downloadPath,
        downloadLimitBytes: _downloadLimitBytes,
        uploadLimitBytes: _uploadLimitBytes,
      );

  @override
  Future<bool> launch() => _serialized(_launchLocked);

  Future<bool> _launchLocked() async {
    if (isClosing || isDisposed) return failWith(EngineStartFailure.closing);

    final executable = await findExecutable();
    final pidFile = await pidFileLocator();

    // 1. The sidecar this session already launched.
    final owned = _owned;
    if (owned != null) {
      final alive = await _isOurs(owned);
      if (alive &&
          executable == owned.executable &&
          owned.sameEndpointAs(_wanted(owned.executable))) {
        // Same port, same folder: keep it. Rate limits wait for its next
        // start, as the settings screen says.
        if (await isRunning() || await waitForReady()) {
          log('rqbit is already running (pid ${owned.pid})');
          return true;
        }
        log('rqbit (pid ${owned.pid}) stopped answering — restarting it');
      } else if (alive) {
        log('engine settings changed — restarting rqbit (pid ${owned.pid})');
      }
      if (alive) await _terminate(owned);
      _owned = null;
      await pidFile.delete();
    }

    // 2. A sidecar an earlier run of the app left behind.
    if (_owned == null && executable != null) {
      final reclaimed = await reclaimOrphan(
        pidFile: pidFile,
        probe: probe,
        wanted: _wanted(executable),
        portAnswering: isRunning,
        windows: Platform.isWindows,
      );
      if (reclaimed != null) {
        _owned = reclaimed;
        log(
          'rqbit is ready (reclaimed pid ${reclaimed.pid} from a previous run)',
        );
        return true;
      }
    }

    // 3. Something we did not start is on the port. Use it, never stop it.
    if (await isRunning()) {
      log(
        'rqbit is already listening on port $port (not started by this app '
        '— it will be left running)',
      );
      return true;
    }

    // 4. Launch our own.
    if (executable == null) {
      log('rqbit executable not found (bundled or on PATH)');
      return failWith(EngineStartFailure.notFound);
    }
    if (isClosing || isDisposed) return failWith(EngineStartFailure.closing);

    final args = buildArguments(
      host: host,
      port: port,
      downloadPath: _downloadPath,
      persistencePath: await statePath(),
      downloadLimitBytes: _downloadLimitBytes,
      uploadLimitBytes: _uploadLimitBytes,
    );
    log('Starting rqbit: $executable ${args.join(' ')}');
    final process = await Process.start(
      executable,
      args,
      // Detached: no console window on Windows, and the sidecar is not tied
      // to this Dart isolate's stdio.
      mode: ProcessStartMode.detached,
    );
    final record = _wanted(executable, pid: process.pid);
    _owned = record;
    await pidFile.write(record);
    log('rqbit started with PID: ${process.pid}');

    if (await waitForReady()) {
      log('rqbit is ready');
      return true;
    }

    log('rqbit failed to become ready — stopping it');
    await _terminate(record);
    _owned = null;
    await pidFile.delete();
    return failWith(EngineStartFailure.didNotStart);
  }

  /// Adopt or remove the sidecar a previous run of the app left behind.
  ///
  /// Reads the launch record and asks the OS whether that process is still
  /// running *the same binary* — a recycled process ID running anything else
  /// is not ours and is never touched. Ours, launched the way this launch
  /// wants and answering on the port: adopted, so it is stopped with the app
  /// like one launched now. Ours, launched differently: stopped, so the new
  /// settings take. Either way the record goes when the process does.
  ///
  /// Returns the adopted record, or null.
  @visibleForTesting
  static Future<EngineLaunchRecord?> reclaimOrphan({
    required EnginePidFile pidFile,
    required EngineProcessProbe probe,
    required EngineLaunchRecord wanted,
    required Future<bool> Function() portAnswering,
    required bool windows,
  }) async {
    final record = await pidFile.read();
    if (record == null) return null;

    final commandLine = await probe.commandLineOf(record.pid);
    final ours =
        commandLine != null &&
        isEngineCommandLine(commandLine, record.executable, windows: windows);
    if (!ours) {
      // Gone, or the ID now belongs to something else. Nothing to stop.
      await pidFile.delete();
      return null;
    }

    if (record.sameLaunchAs(wanted) && await portAnswering()) return record;

    await _terminateWith(probe, record, windows: windows);
    await pidFile.delete();
    return null;
  }

  Future<bool> _isOurs(EngineLaunchRecord record) async {
    final commandLine = await probe.commandLineOf(record.pid);
    return commandLine != null &&
        isEngineCommandLine(
          commandLine,
          record.executable,
          windows: Platform.isWindows,
        );
  }

  Future<void> _terminate(EngineLaunchRecord record) =>
      _terminateWith(probe, record, windows: Platform.isWindows);

  /// Ask [record]'s process to exit, and kill it if it has not within
  /// [terminateGrace]. Checks it is still our binary before every signal.
  static Future<void> _terminateWith(
    EngineProcessProbe probe,
    EngineLaunchRecord record, {
    required bool windows,
  }) async {
    Future<bool> stillOurs() async {
      final line = await probe.commandLineOf(record.pid);
      return line != null &&
          isEngineCommandLine(line, record.executable, windows: windows);
    }

    if (!await stillOurs()) return;
    _staticLog('Stopping rqbit (PID ${record.pid})...');
    probe.kill(record.pid, ProcessSignal.sigterm);

    final deadline = DateTime.now().add(terminateGrace);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!await stillOurs()) {
        _staticLog('rqbit (PID ${record.pid}) stopped');
        return;
      }
    }
    if (!await stillOurs()) return;
    _staticLog(
      'rqbit (PID ${record.pid}) ignored SIGTERM for '
      '${terminateGrace.inMilliseconds} ms — killing it',
    );
    probe.kill(record.pid, ProcessSignal.sigkill);
  }

  /// Stop the sidecar this app is responsible for, whichever service
  /// instance — or engine — is current. Never throws.
  ///
  /// Static because the instance that launched it is routinely gone by the
  /// time it has to stop: the service is rebuilt when its settings change,
  /// and the user may have switched to qBittorrent since. [closing] makes
  /// the stop final for this run of the app — no service may start one again.
  static Future<void> stopOwned({bool closing = false}) {
    if (closing) _closing = true;
    return _serialized(() async {
      try {
        final pidFile = await pidFileLocator();
        final record = _owned ?? await pidFile.read();
        _owned = null;
        if (record != null) {
          await _terminateWith(probe, record, windows: Platform.isWindows);
        }
        await pidFile.delete();
      } catch (e) {
        // Never thrown at the caller: it is the shutdown, or an engine
        // switch that does not wait. The record stays for the next launch.
        _staticLog('could not stop rqbit: $e');
      }
    });
  }

  /// Stop checking on the sidecar and stop it — used when the built-in engine
  /// is switched away from. App shutdown uses [stopOwned] directly.
  @override
  Future<void> stop() async {
    stopKeepingAlive();
    await stopOwned();
  }

  /// Stops the health check but leaves the process running.
  ///
  /// This service is rebuilt whenever its port or download folder changes,
  /// and the replacement decides what to do with the running sidecar when it
  /// starts — keep it, or restart it with the new settings. Killing it here
  /// would interrupt whatever is streaming for every rebuild.
  @override
  void dispose() => super.dispose();
}

/// Log lines from the static half of [RqbitProcessService], tagged the same
/// as the instance's.
void _staticLog(String message) => AppLog.i('[RqbitProcess] $message');
