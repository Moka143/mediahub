import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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

/// Why the last connection attempt failed, for choosing the way out of it.
///
/// [ConnectionState.errorMessage] says it in words; this is for code that has
/// to pick an action — Try again, Settings, a different port — without parsing
/// that sentence.
enum ConnectionFailure {
  /// The built-in engine is not answering, and starting it did not help.
  /// Trying again starts it again.
  engineNotRunning,

  /// The engine program could not be found to start it.
  engineNotFound,

  /// qBittorrent did not answer at the configured address.
  unreachable,

  /// qBittorrent answered and turned the username or password down.
  loginRejected,

  /// The engine took too long to answer.
  timedOut,

  /// Anything else.
  unknown,
}

/// How long a healthy connection goes between checks.
///
/// Deliberately slower than the process health check
/// ([AppConstants.connectionCheckInterval]): that one only probes a local
/// port, while this one makes an API request — with a login behind it for
/// qBittorrent.
const Duration kConnectionCheckInterval = Duration(seconds: 30);

/// How often a dropped connection is retried in the background.
const Duration kReconnectInterval = AppConstants.connectionCheckInterval;

/// Connection state class
class ConnectionState {
  final ConnectionStatus status;
  final String? errorMessage;

  /// Why it failed, when [status] is [ConnectionStatus.error].
  final ConnectionFailure? failure;

  /// The engine's version string, once connected.
  final String? qbVersion;

  const ConnectionState({
    this.status = ConnectionStatus.disconnected,
    this.errorMessage,
    this.failure,
    this.qbVersion,
  });

  /// [errorMessage] and [failure] describe one failed attempt: they carry
  /// over only while the status stays [ConnectionStatus.error], so a
  /// reconnect does not go on showing the previous attempt's error.
  ConnectionState copyWith({
    ConnectionStatus? status,
    String? errorMessage,
    ConnectionFailure? failure,
    String? qbVersion,
  }) {
    final next = status ?? this.status;
    final keepError =
        next == ConnectionStatus.error && this.status == ConnectionStatus.error;
    return ConnectionState(
      status: next,
      errorMessage: errorMessage ?? (keepError ? this.errorMessage : null),
      failure: failure ?? (keepError ? this.failure : null),
      qbVersion: qbVersion ?? this.qbVersion,
    );
  }

  bool get isConnected => status == ConnectionStatus.connected;
  bool get isConnecting => status == ConnectionStatus.connecting;
  bool get hasError => status == ConnectionStatus.error;

  // Value equality, so a `copyWith` that changes nothing does not look like a
  // new state. Riverpod decides whether to recompute dependants with
  // `previous != next`, and with the default identity equality every write —
  // including the no-op connecting -> connecting ones during startup — rebuilt
  // every provider watching this one.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionState &&
          other.status == status &&
          other.errorMessage == errorMessage &&
          other.failure == failure &&
          other.qbVersion == qbVersion;

  @override
  int get hashCode => Object.hash(status, errorMessage, failure, qbVersion);
}

/// The engine process, chosen by the same setting as [torrentEngineProvider].
///
/// The two must agree: an engine pointed at a port nothing is listening on
/// reconnects forever, and a process started for a backend nobody is talking
/// to is a stray daemon.
///
/// Watches only the settings this engine kind's process is built from. It
/// used to watch the whole settings object, so any write at all — a poll
/// interval, the TMDB token, the one-time migration notice being marked seen
/// — disposed the service, and with it the health loop that restarts a
/// crashed engine; the replacement was never started.
final engineProcessProvider = Provider<TorrentEngineProcess>((ref) {
  final kind = ref.watch(settingsProvider.select((s) => s.engineKind));

  final TorrentEngineProcess service;
  if (kind == TorrentEngineKind.builtin) {
    final (port, downloadPath) = ref.watch(
      settingsProvider.select((s) => (s.rqbitPort, s.defaultSavePath)),
    );
    final limits = ref.read(settingsProvider);
    final rqbit = RqbitProcessService(
      port: port,
      downloadPath: downloadPath,
      downloadLimitBytes: limits.downloadSpeedLimit,
      uploadLimitBytes: limits.uploadSpeedLimit,
    );
    // Rate limits are rqbit launch flags. A change waits for the next start —
    // as the settings screen tells the user — instead of restarting an
    // engine that may be streaming.
    ref.listen(
      settingsProvider.select(
        (s) => (s.downloadSpeedLimit, s.uploadSpeedLimit),
      ),
      (_, next) =>
          rqbit.setLaunchLimits(downloadBytes: next.$1, uploadBytes: next.$2),
    );
    service = rqbit;
    // The built-in engine is part of the app: keep it alive whatever the
    // connection is doing.
    rqbit.keepAlive();
  } else {
    final (path, host, port, username, password, autoStart) = ref.watch(
      settingsProvider.select(
        (s) => (
          s.qbittorrentPath,
          s.host,
          s.port,
          s.username,
          s.password,
          s.autoStartQBittorrent,
        ),
      ),
    );
    final qbit = QBittorrentProcessService(
      qbittorrentPath: path,
      port: port,
      host: host,
      requestQuit: () async {
        final api = QBittorrentApiService(
          host: host,
          port: port,
          username: username,
          password: password,
        );
        try {
          return await api.requestShutdown();
        } finally {
          api.dispose();
        }
      },
    );
    service = qbit;
    // Only a qBittorrent the user asked us to manage is restarted for them.
    if (autoStart) qbit.keepAlive();

    // Switching away from the built-in engine stops it. It is ours, it is
    // headless, and nothing on screen would say it was still running.
    unawaited(RqbitProcessService.stopOwned());
  }

  ref.onDispose(service.dispose);
  return service;
});

/// The torrent backend the whole app talks to.
///
/// Typed as [TorrentEngine], not as the concrete service: this is the single
/// place the backend is chosen, so swapping it is a change here and nowhere
/// else. Rebuilt only when the engine kind or the fields that say where and
/// how to reach it change — every rebuild ends the streaming sessions running
/// on the old one, so an unrelated settings write must not cause one.
final torrentEngineProvider = Provider<TorrentEngine>((ref) {
  final kind = ref.watch(settingsProvider.select((s) => s.engineKind));

  final TorrentEngine service;
  if (kind == TorrentEngineKind.builtin) {
    final (port, downloadPath) = ref.watch(
      settingsProvider.select((s) => (s.rqbitPort, s.defaultSavePath)),
    );
    service = RqbitEngine(port: port, defaultSavePath: downloadPath);
  } else {
    final (host, port, username, password) = ref.watch(
      settingsProvider.select((s) => (s.host, s.port, s.username, s.password)),
    );
    service = QBittorrentApiService(
      host: host,
      port: port,
      username: username,
      password: password,
    );
  }

  ref.onDispose(service.dispose);
  return service;
});

/// Provider for connection state
final connectionProvider =
    NotifierProvider<ConnectionNotifier, ConnectionState>(
      ConnectionNotifier.new,
    );

/// Connects to the engine, keeps checking the connection, and reconnects.
///
/// Rebuilds — and so reconnects — whenever the engine or its process is
/// replaced, which is when the engine kind or the address it lives at
/// changes.
class ConnectionNotifier extends Notifier<ConnectionState> {
  late final PollLoop _connectionCheck = PollLoop(
    name: 'connection',
    onTick: _checkConnection,
  );

  /// Bumped on every build. Work started against a replaced engine compares
  /// it after each await and drops its result, so a slow login to the old
  /// engine cannot overwrite the new one's state.
  int _generation = 0;

  @override
  ConnectionState build() {
    ref.watch(torrentEngineProvider);
    ref.watch(engineProcessProvider);
    final generation = ++_generation;

    // `stop()`, not `dispose()`: this callback runs before every rebuild as
    // well as at teardown, and Riverpod reuses this notifier instance across
    // rebuilds. A disposed PollLoop never starts again, so disposing here
    // silenced the connection check for the rest of the session after the
    // first engine switch.
    ref.onDispose(_connectionCheck.stop);

    unawaited(
      Future.microtask(() {
        if (generation == _generation && ref.mounted) unawaited(connect());
      }),
    );

    return const ConnectionState(status: ConnectionStatus.connecting);
  }

  bool _isStale(int generation) => generation != _generation || !ref.mounted;

  /// Start the engine if it is ours to start, then connect to it.
  Future<bool> connect() async {
    final generation = _generation;
    final settings = ref.read(settingsProvider);
    final process = ref.read(engineProcessProvider);
    final engine = ref.read(torrentEngineProvider);
    final builtin = settings.engineKind == TorrentEngineKind.builtin;

    _connectionCheck.stop();
    state = const ConnectionState(status: ConnectionStatus.connecting);

    // The built-in engine is part of the app and is always started. The
    // auto-start toggle is about launching the user's own qBittorrent: it
    // used to gate both, so a user who had turned it off for qBittorrent
    // before the engine migration never got an engine at all.
    final mayLaunch = builtin || settings.autoStartQBittorrent;
    if (mayLaunch && process.managesLocalProcess) {
      final started = await process.start();
      if (_isStale(generation)) return false;
      if (!started) {
        _fail(
          generation,
          _startFailure(builtin, process.lastStartFailure),
          builtin: builtin,
        );
        return false;
      }
    }

    return _login(generation, engine, builtin: builtin, quiet: false);
  }

  /// Log in and finish connecting. [quiet] leaves the visible state alone
  /// unless the attempt succeeds — for background reconnects, which would
  /// otherwise flash "connecting" every few seconds.
  Future<bool> _login(
    int generation,
    TorrentEngine engine, {
    required bool builtin,
    required bool quiet,
  }) async {
    if (!quiet) {
      state = state.copyWith(status: ConnectionStatus.connecting);
    }

    ConnectionFailure failure;
    try {
      final loggedIn = await engine.login();
      if (_isStale(generation)) return false;
      if (loggedIn) {
        final version = await engine.getVersion();
        if (_isStale(generation)) return false;
        state = ConnectionState(
          status: ConnectionStatus.connected,
          qbVersion: version,
        );
        AppLog.i('[Connection] connected to ${_engineName(builtin)}');
        await _syncSpeedLimits(engine);
        if (_isStale(generation)) return true;
        _connectionCheck.start(kConnectionCheckInterval);
        return true;
      }
      // An engine with no login answers false only when it is not there.
      failure = builtin
          ? ConnectionFailure.engineNotRunning
          : ConnectionFailure.loginRejected;
    } on DioException catch (e) {
      failure = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => ConnectionFailure.timedOut,
        DioExceptionType.connectionError =>
          builtin
              ? ConnectionFailure.engineNotRunning
              : ConnectionFailure.unreachable,
        _ => ConnectionFailure.unknown,
      };
    } catch (e) {
      AppLog.w('[Connection] unexpected error while connecting: $e');
      failure = ConnectionFailure.unknown;
    }

    if (_isStale(generation)) return false;
    if (!quiet || state.failure != failure) {
      _fail(generation, failure, builtin: builtin);
    }
    return false;
  }

  ConnectionFailure _startFailure(bool builtin, EngineStartFailure? why) =>
      switch (why) {
        EngineStartFailure.notFound => ConnectionFailure.engineNotFound,
        _ =>
          builtin
              ? ConnectionFailure.engineNotRunning
              : ConnectionFailure.unreachable,
      };

  void _fail(
    int generation,
    ConnectionFailure failure, {
    required bool builtin,
  }) {
    if (_isStale(generation)) return;
    final message = connectionFailureMessage(
      failure,
      builtin: builtin,
      address: builtin ? null : ref.read(torrentEngineProvider).baseUrl,
    );
    AppLog.w('[Connection] $message');
    state = ConnectionState(
      status: ConnectionStatus.error,
      errorMessage: message,
      failure: failure,
    );

    // Keep trying in the background — the engine's own health check may be
    // bringing it back, or the user may start qBittorrent themselves. Never
    // after a rejected login, though: retrying a wrong password every few
    // seconds is how qBittorrent comes to ban this machine's address. Nor
    // for a missing program, which waiting will not fix.
    final retrying =
        failure != ConnectionFailure.loginRejected &&
        failure != ConnectionFailure.engineNotFound;
    if (retrying) {
      _connectionCheck.start(kReconnectInterval);
    } else {
      _connectionCheck.stop();
    }
  }

  /// The words for [failure], naming the engine actually in use.
  @visibleForTesting
  static String connectionFailureMessage(
    ConnectionFailure failure, {
    required bool builtin,
    String? address,
  }) {
    final name = _engineName(builtin);
    return switch (failure) {
      ConnectionFailure.engineNotRunning =>
        "The built-in engine isn't running. Click Try again to restart it, "
            'or pick a different engine port in Settings if another program '
            'is using it.',
      ConnectionFailure.engineNotFound =>
        builtin
            ? "The built-in engine couldn't be found. Reinstall MediaHub, or "
                  'switch to qBittorrent in Settings.'
            : "qBittorrent couldn't be found. Install it, or set where it is "
                  'in Settings.',
      ConnectionFailure.unreachable =>
        "Can't reach qBittorrent${address == null ? '' : ' at $address'}. "
            'Make sure it is running and its Web UI is turned on.',
      ConnectionFailure.loginRejected =>
        'qBittorrent turned down the username or password. Check them in '
            'Settings.',
      ConnectionFailure.timedOut =>
        "${_capitalised(name)} didn't answer in time. Click Try again.",
      ConnectionFailure.unknown =>
        "Couldn't connect to $name. Click Try again.",
    };
  }

  static String _engineName(bool builtin) =>
      builtin ? 'the built-in engine' : 'qBittorrent';

  static String _capitalised(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Push the saved speed limits to an engine that can take them live.
  Future<void> _syncSpeedLimits(TorrentEngine engine) async {
    if (!engine.capabilities.liveSpeedLimits) return;
    try {
      final settings = ref.read(settingsProvider);
      if (settings.downloadSpeedLimit > 0) {
        await engine.setDownloadLimit(settings.downloadSpeedLimit);
      }
      if (settings.uploadSpeedLimit > 0) {
        await engine.setUploadLimit(settings.uploadSpeedLimit);
      }
    } catch (e) {
      AppLog.w('[Connection] could not apply speed limits: $e');
    }
  }

  /// One tick of the connection check.
  ///
  /// Connected: make sure it still is. Not connected: try again, quietly.
  /// This used to stop itself the first time a check failed, so a connection
  /// that dropped — qBittorrent restarted, the built-in engine crashed and
  /// was brought back by its health check — stayed down until someone
  /// clicked Try again.
  Future<void> _checkConnection() async {
    final generation = _generation;
    if (!ref.mounted || state.isConnecting) return;
    final engine = ref.read(torrentEngineProvider);
    final builtin =
        ref.read(settingsProvider).engineKind == TorrentEngineKind.builtin;

    if (state.isConnected) {
      if (await engine.testConnection() || _isStale(generation)) return;
      AppLog.w('[Connection] lost the connection to ${_engineName(builtin)}');
      _fail(
        generation,
        builtin
            ? ConnectionFailure.engineNotRunning
            : ConnectionFailure.unreachable,
        builtin: builtin,
      );
      return;
    }

    await _login(generation, engine, builtin: builtin, quiet: true);
  }

  /// Retry connection
  Future<bool> retry() => connect();
}
