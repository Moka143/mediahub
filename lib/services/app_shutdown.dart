import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/connection_provider.dart';
import 'app_logger.dart';

/// How long the whole teardown may take before we stop asking politely.
///
/// Every step below is bounded on its own, but "bounded" is a property of the
/// code we wrote, not of the plugins and native libraries it calls into. This
/// is the number that holds when one of those does not come back.
const Duration kShutdownDeadline = Duration(seconds: 3);

/// How long the sidecar gets to die. Far longer than a `kill` needs and far
/// shorter than a person will wait.
const Duration kEngineStopTimeout = Duration(seconds: 2);

/// How long queued log lines get to reach disk before the process ends.
const Duration kLogFlushTimeout = Duration(milliseconds: 500);

/// Close the app: hide the window, stop what we started, then go.
///
/// ## Why hiding comes first
///
/// On Windows `windowManager.destroy()` is not a destroy. It is
/// `PostQuitMessage(0)` and nothing else — the HWND is untouched. The runner's
/// `GetMessage` loop exits, `wWinMain` returns, and only then, during stack
/// unwind, does `~Win32Window` run `OnDestroy()` (the engine and every plugin)
/// and *finally* `DestroyWindow`. So the window stays on screen, fully painted
/// and no longer repainting, for the whole of native teardown. That is the
/// "it freezes for about fifteen seconds when I close it" report: not one slow
/// step, just teardown happening somewhere the user can watch it.
///
/// One `ShowWindow(SW_HIDE)` moves all of it out of sight. It is instant, it
/// cannot fail in a way that matters, and it makes every step below invisible.
///
/// ## Why it ends in exit(0) on Windows
///
/// A dying process does not need to tidy up. `exit(0)` is `ExitProcess`: the
/// kernel reclaims libmpv's threads, the ANGLE surface, every socket and every
/// handle, and none of the native destructors run. That matters because two of
/// them cannot be bounded from here — media_kit_video's `~VideoOutput` ends in
/// an untimed `promise.get_future().wait()` for a texture-unregister callback,
/// and `~ThreadPool` then joins a queued `mpv_render_context_free`. Both run on
/// the platform thread *after* the message loop has already exited, so nothing
/// is left to service them. We do not make those waits fast; we stop reaching
/// them.
///
/// What that costs, and therefore the order above:
///   * rqbit is started detached and does *not* die with us, so it has to be
///     killed before the exit — orphaning it is the bug dbc7ad7 fixed.
///   * AppLog writes are queued and flushed asynchronously, so the queue is
///     drained before the exit or the last lines never land.
///   * a close-time save that overran its own budget is still in flight, so
///     [finalWrite] gets one more moment before the exit.
///
/// macOS keeps `destroy()`, which there is a real teardown on a platform with
/// no equivalent problem.
///
/// Every parameter is injectable so a test can call this exact function rather
/// than a copy of it — the copy in `test/shutdown_test.dart` used to drift from
/// this one silently, and `container.dispose()` was on nobody's tested path.
Future<void> shutDown(
  ProviderContainer container, {
  Future<void> Function()? hide,
  Future<void> Function()? destroy,
  Future<void> Function()? finalWrite,
  void Function(int code)? terminate,
  bool? useExit,
  Duration deadline = kShutdownDeadline,
  Duration engineStopTimeout = kEngineStopTimeout,
}) async {
  // Closures, not tear-offs: `windowManager` is a lazy singleton whose
  // constructor installs a method-call handler, so naming it here would reach
  // for a platform channel even on the paths that never use it — which is an
  // assertion failure under `flutter test`, where no binding exists.
  final Future<void> Function() hideWindow = hide ?? () => windowManager.hide();
  final Future<void> Function() destroyWindow =
      destroy ?? () => windowManager.destroy();
  final void Function(int code) exitProcess = terminate ?? exit;
  final hardExit = useExit ?? Platform.isWindows;

  // The backstop, and the only promise this file can actually keep. If the
  // teardown is still going when this fires, the process ends regardless of
  // what it was waiting for. Cancelled immediately before each terminal step,
  // because past that point there is nothing left to guard.
  final watchdog = Timer(deadline, () {
    AppLog.e('[Shutdown] deadline exceeded — forcing exit');
    exitProcess(0);
  });

  // 1. Get off the screen. See the doc comment: this is the symptom fix.
  await _bounded(
    'hide the window',
    hideWindow,
    const Duration(milliseconds: 250),
  );

  // 2. Kill our sidecar while we still can.
  //
  // Only ever a process *we* started — `RqbitProcessService.stop` refuses to
  // touch an engine the user runs themselves, and that stays true here.
  await _bounded(
    'stop the engine',
    () => container.read(engineProcessProvider).stop(),
    engineStopTimeout,
  );

  // 3. Provider teardown, guarded. This used to sit bare: a synchronous throw
  //    out of `dispose()` took the window destruction with it, and because
  //    `main` sets `setPreventClose(true)` that left the user holding a window
  //    which would not close. A teardown failure must never trap someone in an
  //    app they have already asked to leave.
  //
  //    A throw inside an `onDispose` callback does NOT arrive here and cannot
  //    be caught from this function: Riverpod runs those guarded and reports
  //    them to the zone the container was *built* in, which is `main`'s
  //    `runZonedGuarded`. That handler exits the process, so the close still
  //    completes — it is just logged as a startup fatal rather than as this.
  //    Fixing the label means passing an `onError` to the ProviderContainer in
  //    `main`, which is a decision about the whole app, not about closing it.
  try {
    container.dispose();
  } catch (e, st) {
    AppLog.w('[Shutdown] provider teardown failed: $e\n$st');
  }

  // 4. The close-time save stopped being *waited on* after its own timeout,
  //    but the write is still running. Give it a last moment rather than
  //    letting exit() cut it off mid-file.
  if (finalWrite != null) {
    await _bounded(
      'finish the window-state save',
      finalWrite,
      const Duration(milliseconds: 400),
    );
  }

  // 5. Drain the log queue. exit() does not do this for us, and the lines
  //    worth having are the ones written during the close.
  AppLog.i('[Shutdown] done — closing');
  try {
    await AppLog.idle.timeout(kLogFlushTimeout);
  } catch (_) {
    // A log that will not flush is not a reason to stay open.
  }

  if (hardExit) {
    watchdog.cancel();
    exitProcess(0);
    return; // Only reached under test, where exitProcess is injected.
  }

  await _bounded(
    'destroy the window',
    destroyWindow,
    const Duration(seconds: 1),
  );
  watchdog.cancel();
}

/// Run [action] with a budget, and treat every failure as non-fatal.
///
/// Nothing in a shutdown is important enough to stop the shutdown.
Future<void> _bounded(
  String what,
  Future<void> Function() action,
  Duration budget,
) async {
  try {
    await action().timeout(budget);
  } catch (e) {
    AppLog.w('[Shutdown] could not $what: $e');
  }
}
