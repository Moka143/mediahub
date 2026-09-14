import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/services/app_shutdown.dart';
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

/// A container holding nothing but the fake engine, so `dispose()` is on the
/// tested path without dragging in prefs, the secret store or settings.
ProviderContainer _containerWith(TorrentEngineProcess engine) =>
    ProviderContainer(
      overrides: [engineProcessProvider.overrideWithValue(engine)],
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('shutdown', () {
    test('hides the window, stops the engine, then exits', () async {
      // Hiding first is the whole of the perceived-hang fix. On Windows
      // `windowManager.destroy()` is only PostQuitMessage(0), so the window
      // sits on screen, painted and frozen, for the entire native teardown
      // that follows. Everything after the hide happens out of sight.
      final engine = _FakeEngineProcess();
      var hidden = false;
      int? code;

      await shutDown(
        _containerWith(engine),
        hide: () async => hidden = true,
        terminate: (c) => code = c,
        useExit: true,
      );

      expect(hidden, isTrue);
      expect(
        engine.stopped,
        isTrue,
        reason: 'the sidecar is detached and does not die with us',
      );
      expect(code, 0);
    });

    test('an engine that hangs does not trap the user in the app', () async {
      final engine = _FakeEngineProcess(stopDelay: const Duration(seconds: 30));
      int? code;

      await shutDown(
        _containerWith(engine),
        hide: () async {},
        terminate: (c) => code = c,
        useExit: true,
        engineStopTimeout: const Duration(milliseconds: 50),
      );

      expect(engine.stopped, isFalse, reason: 'it never finished');
      expect(code, 0, reason: 'we leave anyway');
    });

    test('an engine that throws does not trap them either', () async {
      int? code;

      await shutDown(
        _containerWith(_FakeEngineProcess(throwOnStop: true)),
        hide: () async {},
        terminate: (c) => code = c,
        useExit: true,
      );

      expect(code, 0);
    });

    test('a provider that throws on dispose cannot block the exit', () async {
      // The case the old hand-written copy of this function could not see at
      // all: it never called `container.dispose()`, so provider teardown was
      // on nobody's tested path.
      //
      // Riverpod runs `onDispose` callbacks guarded and reports a throw to the
      // zone the container was *built* in rather than out of `dispose()` — so
      // the container has to be built inside the zone here, exactly as the
      // real one is built inside `main`'s `runZonedGuarded`. What matters is
      // that the close still reaches its exit.
      int? code;
      Object? reported;
      await runZonedGuarded(() async {
        final container = _containerWith(_FakeEngineProcess());
        final boobyTrap = Provider<int>((ref) {
          ref.onDispose(() => throw StateError('dispose exploded'));
          return 1;
        });
        container.read(boobyTrap);

        await shutDown(
          container,
          hide: () async {},
          terminate: (c) => code = c,
          useExit: true,
        );
      }, (error, _) => reported = error);

      expect(code, 0, reason: 'the close still finishes');
      expect(
        reported,
        isStateError,
        reason: 'and the failure is surfaced, not swallowed',
      );
    });

    test('a hide that never answers does not hold the close up', () async {
      // window_manager is a method channel; an unanswered call is a real
      // failure mode and must not be the thing that keeps the app open.
      int? code;

      await shutDown(
        _containerWith(_FakeEngineProcess()),
        hide: () => Completer<void>().future,
        terminate: (c) => code = c,
        useExit: true,
      );

      expect(code, 0);
    });

    test('the deadline ends it even when a step never returns', () async {
      // The backstop, and the only promise the shutdown can actually keep:
      // every budget above it is a property of our code, not of the native
      // libraries it calls into.
      final engine = _FakeEngineProcess(stopDelay: const Duration(seconds: 30));
      final exited = Completer<int>();

      unawaited(
        shutDown(
          _containerWith(engine),
          hide: () async {},
          terminate: (c) {
            if (!exited.isCompleted) exited.complete(c);
          },
          useExit: true,
          engineStopTimeout: const Duration(seconds: 30),
          deadline: const Duration(milliseconds: 100),
        ),
      );

      expect(await exited.future.timeout(const Duration(seconds: 2)), 0);
    });

    test('macOS destroys the window instead of exiting', () async {
      // exit(0) is a Windows answer to a Windows problem. The Mac teardown is
      // real and there is no equivalent hang to dodge, so it keeps destroy().
      var destroyed = false;
      var exited = false;

      await shutDown(
        _containerWith(_FakeEngineProcess()),
        hide: () async {},
        destroy: () async => destroyed = true,
        terminate: (_) => exited = true,
        useExit: false,
      );

      expect(destroyed, isTrue);
      expect(exited, isFalse);
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
