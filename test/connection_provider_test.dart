import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/services/torrent_engine.dart';
import 'package:mediahub/services/torrent_engine_process.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeProcess implements TorrentEngineProcess {
  _FakeProcess({this.startResult = true, this.failure});

  final bool startResult;
  final EngineStartFailure? failure;
  int starts = 0;

  @override
  bool get managesLocalProcess => true;

  @override
  Future<bool> isRunning() async => startResult;

  @override
  Future<bool> start() async {
    starts++;
    return startResult;
  }

  @override
  EngineStartFailure? get lastStartFailure => startResult ? null : failure;

  @override
  void keepAlive() {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}

class _FakeEngine extends TorrentEngine {
  _FakeEngine({this.loginResult = true, this.loginError});

  final bool loginResult;
  final Object? loginError;
  int logins = 0;

  @override
  String get baseUrl => 'http://localhost:8080';

  @override
  Future<bool> login() async {
    logins++;
    if (loginError != null) throw loginError!;
    return loginResult;
  }

  @override
  Future<bool> testConnection() async => loginResult;

  @override
  Future<String?> getVersion() async => 'test';

  @override
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes}) async =>
      const [];

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async => const [];

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    bool? paused,
    bool? sequentialDownload,
  }) async => true;

  @override
  Future<bool> pauseTorrents(List<String> hashes) async => true;

  @override
  Future<bool> resumeTorrents(List<String> hashes) async => true;

  @override
  Future<bool> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async => true;

  @override
  Future<bool> setFilePriority(String h, List<int> ids, int p) async => true;

  @override
  Future<List<int>?> getPieceStates(String hash) async => null;

  @override
  void dispose() {}
}

Future<SharedPreferences> _prefs(Map<String, Object?> settings) async {
  SharedPreferences.setMockInitialValues({
    'flutter.app_settings': jsonEncode(settings),
  });
  return SharedPreferences.getInstance();
}

Future<ConnectionState> _settle(ProviderContainer container) async {
  // `build` schedules the first connect on a microtask; give it a moment.
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final state = container.read(connectionProvider);
    if (!state.isConnecting) return state;
  }
  return container.read(connectionProvider);
}

void main() {
  group('starting the engine', () {
    Future<(ProviderContainer, _FakeProcess, _FakeEngine)> build({
      required TorrentEngineKind kind,
      required bool autoStart,
      _FakeProcess? process,
      _FakeEngine? engine,
    }) async {
      final prefs = await _prefs({
        'engine_kind': kind.index,
        'auto_start_qbittorrent': autoStart,
      });
      final p = process ?? _FakeProcess();
      final e = engine ?? _FakeEngine();
      final container = ProviderContainer.test(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProcessProvider.overrideWithValue(p),
          torrentEngineProvider.overrideWithValue(e),
        ],
      );
      container.read(connectionProvider);
      return (container, p, e);
    }

    test(
      'the built-in engine starts whatever the qBittorrent toggle says',
      () async {
        // The auto-start toggle is about launching the user's own qBittorrent.
        // It used to gate the built-in engine too, so users who had it off
        // never got an engine at all.
        final (container, process, _) = await build(
          kind: TorrentEngineKind.builtin,
          autoStart: false,
        );
        final state = await _settle(container);
        expect(process.starts, 1);
        expect(state.isConnected, isTrue);
      },
    );

    test('qBittorrent is only launched when auto-start is on', () async {
      final (off, offProcess, offEngine) = await build(
        kind: TorrentEngineKind.qbittorrent,
        autoStart: false,
      );
      await _settle(off);
      expect(offProcess.starts, 0);
      expect(offEngine.logins, 1, reason: 'still connects to a running one');

      final (on, onProcess, _) = await build(
        kind: TorrentEngineKind.qbittorrent,
        autoStart: true,
      );
      await _settle(on);
      expect(onProcess.starts, 1);
    });
  });

  group('saying what went wrong', () {
    Future<ConnectionState> attempt({
      required TorrentEngineKind kind,
      _FakeProcess? process,
      _FakeEngine? engine,
    }) async {
      final prefs = await _prefs({'engine_kind': kind.index});
      final container = ProviderContainer.test(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProcessProvider.overrideWithValue(process ?? _FakeProcess()),
          torrentEngineProvider.overrideWithValue(engine ?? _FakeEngine()),
        ],
      );
      container.read(connectionProvider);
      return _settle(container);
    }

    test('a built-in engine that is not answering says so', () async {
      // rqbit has no login: false means not running — never a password.
      final state = await attempt(
        kind: TorrentEngineKind.builtin,
        engine: _FakeEngine(loginResult: false),
      );
      expect(state.hasError, isTrue);
      expect(state.failure, ConnectionFailure.engineNotRunning);
      expect(state.errorMessage, contains("The built-in engine isn't running"));
      expect(state.errorMessage, contains('Try again'));
      expect(state.errorMessage!.toLowerCase(), isNot(contains('password')));
      expect(state.errorMessage!.toLowerCase(), isNot(contains('authent')));
    });

    test('a built-in engine refusing connections says so too', () async {
      final state = await attempt(
        kind: TorrentEngineKind.builtin,
        engine: _FakeEngine(
          loginError: DioException.connectionError(
            requestOptions: RequestOptions(path: '/'),
            reason: 'Connection refused',
          ),
        ),
      );
      expect(state.failure, ConnectionFailure.engineNotRunning);
    });

    test('a missing engine program is not "not running"', () async {
      final state = await attempt(
        kind: TorrentEngineKind.builtin,
        process: _FakeProcess(
          startResult: false,
          failure: EngineStartFailure.notFound,
        ),
      );
      expect(state.failure, ConnectionFailure.engineNotFound);
      expect(state.errorMessage, contains("couldn't be found"));
    });

    test('a wrong qBittorrent password is a login problem', () async {
      final state = await attempt(
        kind: TorrentEngineKind.qbittorrent,
        engine: _FakeEngine(loginResult: false),
      );
      expect(state.failure, ConnectionFailure.loginRejected);
      expect(state.errorMessage, contains('username or password'));
    });

    test('an unreachable qBittorrent names the address', () async {
      final state = await attempt(
        kind: TorrentEngineKind.qbittorrent,
        engine: _FakeEngine(
          loginError: DioException.connectionError(
            requestOptions: RequestOptions(path: '/'),
            reason: 'refused',
          ),
        ),
      );
      expect(state.failure, ConnectionFailure.unreachable);
      expect(state.errorMessage, contains('http://localhost:8080'));
    });
  });

  group('ConnectionState.copyWith', () {
    test('an error does not outlive the attempt it belongs to', () {
      const failed = ConnectionState(
        status: ConnectionStatus.error,
        errorMessage: 'old',
        failure: ConnectionFailure.timedOut,
      );
      final retrying = failed.copyWith(status: ConnectionStatus.connecting);
      expect(retrying.errorMessage, isNull);
      expect(retrying.failure, isNull);
    });

    test('an error stays while the status stays an error', () {
      const failed = ConnectionState(
        status: ConnectionStatus.error,
        errorMessage: 'old',
      );
      expect(failed.copyWith(qbVersion: 'x').errorMessage, 'old');
    });
  });

  group('engine providers', () {
    test(
      'an unrelated settings write keeps the same engine and process',
      () async {
        // Watching the whole settings object replaced both on every write — the
        // migration notice being marked seen was enough — which ended every
        // streaming session and the crash-restart health loop with them.
        final prefs = await _prefs({
          'engine_kind': TorrentEngineKind.builtin.index,
        });
        final container = ProviderContainer.test(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );
        final engine = container.read(torrentEngineProvider);
        final process = container.read(engineProcessProvider);

        final settings = container.read(settingsProvider.notifier);
        await settings.setUpdateInterval(7);
        await settings.setBingeWatchingEnabled(false);
        await settings.setDownloadSpeedLimit(1024);

        expect(
          identical(container.read(torrentEngineProvider), engine),
          isTrue,
        );
        expect(
          identical(container.read(engineProcessProvider), process),
          isTrue,
        );
      },
    );

    test('a change to where the engine lives does replace it', () async {
      final prefs = await _prefs({
        'engine_kind': TorrentEngineKind.builtin.index,
      });
      final container = ProviderContainer.test(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      final engine = container.read(torrentEngineProvider);

      await container.read(settingsProvider.notifier).setRqbitPort(4040);

      expect(identical(container.read(torrentEngineProvider), engine), isFalse);
      expect(container.read(torrentEngineProvider).baseUrl, contains('4040'));
    });
  });
}
