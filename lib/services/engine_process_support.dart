import 'dart:async';

import 'package:flutter/foundation.dart';

import '../utils/constants.dart';
import '../utils/platform_utils.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';
import 'torrent_engine_process.dart';

/// What the rqbit and qBittorrent process services have in common: probing
/// the API port, waiting for a launched engine to answer, and a health loop
/// that starts a dead engine again.
///
/// Both used to carry their own copies, and the copies had already drifted —
/// only one had the closing guard that stops the health loop relaunching an
/// engine the shutdown has just stopped, and only one reset its "starting"
/// flag in a `finally`; the other did it by hand on five separate paths.
abstract class EngineProcessSupport implements TorrentEngineProcess {
  EngineProcessSupport({
    required this.engineName,
    required this.logTag,
    required this.host,
    required this.port,
  });

  /// The engine's name in log lines, e.g. `rqbit`.
  final String engineName;

  /// The tag log lines carry, e.g. `RqbitProcess`.
  final String logTag;
  final String host;
  final int port;

  late final PollLoop _healthCheck = PollLoop(
    name: '$engineName-health',
    onTick: _checkHealth,
  );
  Future<bool>? _startInFlight;
  bool _disposed = false;
  EngineStartFailure? _lastStartFailure;

  /// True once the app has begun closing. An engine started after that point
  /// would outlive the app with nothing left to stop it.
  bool get isClosing;

  /// Whether this instance has been replaced or torn down. A replaced
  /// instance's health loop must not start an engine with stale settings.
  @protected
  bool get isDisposed => _disposed;

  @override
  EngineStartFailure? get lastStartFailure => _lastStartFailure;

  @override
  bool get managesLocalProcess => PlatformUtils.isLocalHost(host);

  @override
  Future<bool> isRunning() => PlatformUtils.isPortInUse(port, host: host);

  /// Launch the engine, or adopt one already serving the port, and wait
  /// until it answers. Implementations report why they failed through
  /// [failWith].
  @protected
  Future<bool> launch();

  /// Record why [launch] is about to answer false.
  @protected
  bool failWith(EngineStartFailure failure) {
    _lastStartFailure = failure;
    return false;
  }

  /// Start the engine if it is not running.
  ///
  /// Callers that overlap — the connection's first connect, a health check
  /// that fires during it, a Retry — share one attempt instead of the second
  /// one answering false, which the connection used to report as "failed to
  /// start".
  @override
  Future<bool> start() {
    if (isClosing || _disposed) {
      log(
        'not starting $engineName — '
        '${isClosing ? 'the app is closing' : 'this service was replaced'}',
      );
      _lastStartFailure = EngineStartFailure.closing;
      return Future<bool>.value(false);
    }
    return _startInFlight ??= _runLaunch().whenComplete(
      () => _startInFlight = null,
    );
  }

  Future<bool> _runLaunch() async {
    _lastStartFailure = null;
    try {
      final ok = await launch();
      if (ok) {
        _lastStartFailure = null;
        keepAlive();
      } else {
        _lastStartFailure ??= EngineStartFailure.didNotStart;
      }
      return ok;
    } catch (e) {
      log('could not start $engineName: $e');
      _lastStartFailure = EngineStartFailure.didNotStart;
      return false;
    }
  }

  /// How long a launched engine gets to start answering.
  static const Duration readyTimeout = Duration(seconds: 30);

  /// How often the port is probed while waiting. A loopback connect is cheap,
  /// and a short step is also what lets a shutdown that lands mid-wait cut it
  /// short instead of sitting out a long backoff delay first.
  static const Duration readyPollStep = Duration(milliseconds: 250);

  /// Poll the port until something answers, the app starts closing, or
  /// [timeout] passes.
  @protected
  Future<bool> waitForReady({Duration timeout = readyTimeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(readyPollStep);
      if (isClosing || _disposed) return false;
      if (await isRunning()) return true;
    }
    return false;
  }

  /// Check on the engine every few seconds and start it again if it has
  /// died. Safe to call repeatedly; a no-op for an engine on another machine.
  @override
  void keepAlive() {
    if (_disposed || isClosing || !managesLocalProcess) return;
    if (_healthCheck.isRunning) return;
    _healthCheck.start(AppConstants.connectionCheckInterval);
  }

  /// Stop checking on the engine, without stopping the engine.
  @protected
  void stopKeepingAlive() => _healthCheck.stop();

  Future<void> _checkHealth() async {
    if (isClosing || _disposed) return;
    if (await isRunning()) return;
    // Re-checked after the probe: the shutdown or a settings change can land
    // while it is in flight, and a restart after either is exactly the
    // orphan this guard exists to prevent.
    if (isClosing || _disposed) return;
    log('$engineName is not answering on port $port — starting it again');
    await start();
  }

  @override
  void dispose() {
    _disposed = true;
    _healthCheck.dispose();
  }

  @protected
  void log(String message) => AppLog.i('[$logTag] $message');

  @protected
  void debug(String message) => AppLog.d('[$logTag] $message');
}
