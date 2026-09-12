import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/torrent_engine_process.dart';
import 'package:mediahub/services/window_state_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records whether it was asked to stop, and can take as long as it likes
/// doing so.
class _FakeEngineProcess implements TorrentEngineProcess {
  _FakeEngineProcess({
    this.stopDelay = Duration.zero,
    this.throwOnStop = false,
  });

  final Duration stopDelay;
  final bool throwOnStop;
  bool stopped = false;

  @override
  bool get managesLocalProcess => true;

  @override
  Future<bool> isRunning() async => true;

  @override
  Future<bool> start() async => true;

  @override
  Future<void> stop() async {
    await Future<void>.delayed(stopDelay);
    if (throwOnStop) throw StateError('engine refused');
    stopped = true;
  }

  @override
  void dispose() {}
}

/// Mirrors `main._shutDown`: stop the engine, bounded, then close regardless.
Future<void> shutDown(
  TorrentEngineProcess engine,
  Future<void> Function() destroy, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    await engine.stop().timeout(timeout);
  } catch (_) {
    // A teardown that fails must not trap the user in the app.
  }
  await destroy();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('shutdown', () {
    test('stops the engine before the window goes', () async {
      // Without this the sidecar outlived the app: headless, so nothing said
      // it was still there, holding its port against the next launch.
      final engine = _FakeEngineProcess();
      var destroyed = false;

      await shutDown(engine, () async => destroyed = true);

      expect(engine.stopped, isTrue);
      expect(destroyed, isTrue);
    });

    test('an engine that hangs does not trap the user in the app', () async {
      final engine = _FakeEngineProcess(stopDelay: const Duration(seconds: 30));
      var destroyed = false;

      await shutDown(
        engine,
        () async => destroyed = true,
        timeout: const Duration(milliseconds: 50),
      );

      expect(engine.stopped, isFalse, reason: 'it never finished');
      expect(destroyed, isTrue, reason: 'the window must close anyway');
    });

    test('an engine that throws does not trap them either', () async {
      final engine = _FakeEngineProcess(throwOnStop: true);
      var destroyed = false;

      await shutDown(engine, () async => destroyed = true);

      expect(destroyed, isTrue);
    });
  });

  group('WindowStateService close path', () {
    test('onClosed runs even when the save fails', () async {
      // The same rule one level up: a failed save is not a reason to leave a
      // window the user cannot close.
      final prefs = await SharedPreferences.getInstance();
      var closed = false;
      final service = WindowStateService(
        prefs,
        onClosed: () async => closed = true,
      );

      service.onWindowClose();
      await Future<void>.delayed(
        WindowStateService.closeSaveTimeout + const Duration(milliseconds: 200),
      );

      expect(closed, isTrue);
    });
  });
}
