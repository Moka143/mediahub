import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/app_shutdown.dart';
import 'package:mediahub/services/window_state_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what the teardown did, in order.
class _Harness {
  _Harness({
    this.engineStopDelay = Duration.zero,
    this.engineThrows = false,
    bool exitsProcess = true,
    Duration deadline = const Duration(seconds: 5),
    Duration engineStopTimeout = const Duration(seconds: 2),
    Future<void> Function()? hide,
  }) {
    shutdown = AppShutdown(
      hideWindow: hide ?? () async => steps.add('hide'),
      closeApp: () async => steps.add('quit'),
      stopEngines: () async {
        engineStops++;
        await Future<void>.delayed(engineStopDelay);
        if (engineThrows) throw StateError('engine refused');
        steps.add('engines stopped');
      },
      exitProcess: (code) {
        exitCodes.add(code);
        steps.add('exit $code');
      },
      exitsProcess: exitsProcess,
      deadline: deadline,
      engineStopTimeout: engineStopTimeout,
    )..saveWindowState = () async => steps.add('window saved');
  }

  final Duration engineStopDelay;
  final bool engineThrows;
  late final AppShutdown shutdown;
  final List<String> steps = [];
  final List<int> exitCodes = [];
  int engineStops = 0;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppShutdown.run', () {
    test('hides the window first, then stops the engine and saves', () async {
      // Hiding first is the whole of the perceived-hang fix. On Windows
      // `windowManager.destroy()` is only PostQuitMessage(0), so the window
      // sits on screen, painted and frozen, for the entire native teardown.
      final h = _Harness();
      final container = ProviderContainer();
      var providersDisposed = false;
      final probe = Provider<int>((ref) {
        ref.onDispose(() => providersDisposed = true);
        return 0;
      });
      container.read(probe);
      h.shutdown.container = container;

      await h.shutdown.run();
      h.shutdown.cancelWatchdog();

      expect(h.steps.first, 'hide');
      expect(h.steps, containsAll(['engines stopped', 'window saved']));
      expect(providersDisposed, isTrue);
    });

    test('tears down exactly once, however many exit paths fire', () async {
      // On macOS a single click on the close button reaches here three ways:
      // the window's close event, the quit AppKit starts when the window is
      // hidden, and the quit the close handler itself starts at the end.
      final h = _Harness(exitsProcess: false);

      await Future.wait([
        h.shutdown.closeFromWindow(),
        h.shutdown.prepareToQuit(),
        h.shutdown.didRequestAppExit(),
        h.shutdown.run(),
      ]);
      h.shutdown.cancelWatchdog();

      expect(h.engineStops, 1);
      expect(h.steps.where((s) => s == 'hide'), hasLength(1));
    });

    test('every quit path waits for the teardown before answering', () async {
      final h = _Harness(
        exitsProcess: false,
        engineStopDelay: const Duration(milliseconds: 100),
      );

      final answer = await h.shutdown.didRequestAppExit();
      h.shutdown.cancelWatchdog();

      expect(answer, AppExitResponse.exit);
      expect(
        h.steps,
        contains('engines stopped'),
        reason: 'the framework is told "exit" only after the engine stopped',
      );
      expect(await h.shutdown.prepareToQuit(), isTrue);
    });

    test('a closing window on Windows ends the process', () async {
      final h = _Harness();
      await h.shutdown.closeFromWindow();
      expect(h.exitCodes, [0]);
      expect(h.steps.last, 'exit 0');
      expect(h.steps, isNot(contains('quit')));
    });

    test('an app exit request on Windows ends the process too', () async {
      final h = _Harness();
      await h.shutdown.didRequestAppExit();
      expect(h.exitCodes, [0]);
    });

    test('macOS hands over to AppKit instead of exiting', () async {
      final h = _Harness(exitsProcess: false);
      await h.shutdown.closeFromWindow();
      h.shutdown.cancelWatchdog();
      expect(h.steps.last, 'quit');
      expect(h.exitCodes, isEmpty);
    });

    test('an engine that hangs does not trap the user in the app', () async {
      final h = _Harness(
        engineStopDelay: const Duration(seconds: 30),
        engineStopTimeout: const Duration(milliseconds: 50),
      );
      await h.shutdown.closeFromWindow();
      expect(h.exitCodes, [0], reason: 'we leave anyway');
    });

    test('an engine that throws does not trap them either', () async {
      final h = _Harness(engineThrows: true);
      await h.shutdown.closeFromWindow();
      expect(h.exitCodes, [0]);
    });

    test('a hide that never answers does not hold the close up', () async {
      final h = _Harness(hide: () => Completer<void>().future);
      await h.shutdown.closeFromWindow();
      expect(h.exitCodes, [0]);
    });

    test('the deadline ends it even when a step never returns', () async {
      // The backstop, and the only promise the shutdown can actually keep:
      // every budget above it is a property of our code, not of the native
      // libraries it calls into.
      final h = _Harness(
        exitsProcess: false,
        engineStopDelay: const Duration(seconds: 30),
        engineStopTimeout: const Duration(seconds: 30),
        deadline: const Duration(milliseconds: 100),
      );
      unawaited(h.shutdown.run());
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(h.exitCodes, [0]);
    });

    test('a provider that throws on dispose cannot block the exit', () async {
      // Riverpod runs `onDispose` callbacks guarded and reports a throw to the
      // zone the container was *built* in — so it is built inside the zone
      // here, as the real one is inside `main`'s `runZonedGuarded`.
      final h = _Harness();
      Object? reported;
      await runZonedGuarded(() async {
        final container = ProviderContainer();
        final boobyTrap = Provider<int>((ref) {
          ref.onDispose(() => throw StateError('dispose exploded'));
          return 1;
        });
        container.read(boobyTrap);
        h.shutdown.container = container;
        await h.shutdown.closeFromWindow();
      }, (error, _) => reported = error);

      expect(h.exitCodes, [0], reason: 'the close still finishes');
      expect(reported, isStateError, reason: 'and the failure is surfaced');
    });

    test('a teardown that begins says so', () async {
      final h = _Harness(exitsProcess: false);
      expect(h.shutdown.isShuttingDown, isFalse);
      unawaited(h.shutdown.run());
      expect(h.shutdown.isShuttingDown, isTrue);
      await h.shutdown.run();
      h.shutdown.cancelWatchdog();
    });
  });

  group('WindowStateService close path', () {
    test('a close goes to the shutdown, which owns the rest', () async {
      final prefs = await SharedPreferences.getInstance();
      var requested = 0;
      final service = WindowStateService(
        prefs,
        onCloseRequested: () async => requested++,
      );

      service.onWindowClose();
      await Future<void>.delayed(Duration.zero);

      expect(requested, 1);
    });

    test('the close-time save never throws into the shutdown', () async {
      // No window_manager plugin behind a unit test, so the save fails —
      // standing in for a locked prefs file or a native call that errors.
      final prefs = await SharedPreferences.getInstance();
      final service = WindowStateService(prefs, onCloseRequested: () async {});

      await expectLater(service.saveForClose(), completes);
      await expectLater(service.pendingSave, completes);
    });
  });
}
