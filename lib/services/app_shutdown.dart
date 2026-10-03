import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';
import 'qbittorrent_process_service.dart';
import 'rqbit_process_service.dart';

/// How long the whole teardown may take before we stop asking politely.
///
/// Every step below is bounded on its own, but "bounded" is a property of the
/// code we wrote, not of the plugins and native libraries it calls into. This
/// is the number that holds when one of those does not come back.
const Duration kShutdownDeadline = Duration(seconds: 5);

/// How long the engines get to stop. Room for rqbit to exit on SIGTERM —
/// [RqbitProcessService.terminateGrace] — and be killed if it does not.
const Duration kEngineStopTimeout = Duration(seconds: 2);

/// How long the window position gets to be saved.
const Duration kWindowSaveTimeout = Duration(seconds: 2);

/// How long queued log lines get to reach disk before the process ends.
const Duration kLogFlushTimeout = Duration(milliseconds: 500);

/// Stop every engine process this run of the app started, whichever engine
/// is selected now: our rqbit is killed, and a qBittorrent we launched is
/// asked to quit. Both are told the app is closing, so a health check that is
/// already in flight cannot start one again moments later.
Future<void> stopAllEngines() async {
  await Future.wait([
    RqbitProcessService.stopOwned(closing: true),
    QBittorrentProcessService.quitIfLaunched(closing: true),
  ]);
}

/// The one way out of the app.
///
/// Every exit path ends up in [run], which tears down exactly once however
/// many paths fire — and on macOS several do for a single click:
///
///  * **The window's close button**, ⌘W, Alt+F4, the taskbar's Close window:
///    window_manager reports the close (the app sets `preventClose`) and
///    [closeFromWindow] runs.
///  * **Quitting the app** — ⌘Q, Dock → Quit, logging out, an AppleScript
///    `quit`: on macOS the app delegate holds AppKit's quit open and asks for
///    [run] over a method channel (see `AppDelegate.swift`); elsewhere the
///    framework's exit request reaches [didRequestAppExit].
///  * **Hiding the last window.** [run] starts by hiding the window, and on
///    macOS that is enough for AppKit to start a quit of its own, because the
///    app terminates after its last window closes. That quit used to go
///    straight to the framework, which with no exit handler said "exit" at
///    once — so a release build died a few milliseconds into its own close
///    handler, before it had stopped the engine. Every quit now waits for
///    [run].
///  * **Signing out or shutting down Windows**: the runner window answers
///    `WM_ENDSESSION` by asking for [prepareToQuit] over the same channel and
///    waiting for it (see `windows/runner/flutter_window.cpp`). The framework
///    is never told, and once that message is answered Windows may end the
///    process at any moment.
///  * **SIGTERM / SIGINT** on macOS and Linux, wired in `main`.
///
/// ## Why hiding comes first
///
/// On Windows `windowManager.destroy()` is not a destroy. It is
/// `PostQuitMessage(0)` and nothing else — the HWND is untouched. The runner's
/// `GetMessage` loop exits, `wWinMain` returns, and only then, during stack
/// unwind, does `~Win32Window` run `OnDestroy()` (the engine and every plugin)
/// and *finally* `DestroyWindow`. So the window stays on screen, fully painted
/// and no longer repainting, for the whole of native teardown — the "it
/// freezes for about fifteen seconds when I close it" report. One
/// `ShowWindow(SW_HIDE)` moves all of it out of sight.
///
/// ## Why it ends in exit(0) on Windows
///
/// A dying process does not need to tidy up. `exit(0)` is `ExitProcess`: the
/// kernel reclaims libmpv's threads, the ANGLE surface, every socket and every
/// handle, and none of the native destructors run. Two of them cannot be
/// bounded from here — media_kit_video's `~VideoOutput` ends in an untimed
/// wait for a texture-unregister callback, and `~ThreadPool` then joins a
/// queued `mpv_render_context_free` — so we stop reaching them.
///
/// What that costs, and therefore the order in [run]:
///   * rqbit is started detached and does *not* die with us, so it is stopped
///     before the exit — orphaning it is the bug this class exists for;
///   * AppLog writes are queued, so the queue is drained before the exit;
///   * the close-time window save is finished before the exit.
///
/// macOS keeps AppKit's own termination, which there is a real teardown on a
/// platform with no equivalent problem.
class AppShutdown with WidgetsBindingObserver {
  AppShutdown({
    Future<void> Function()? hideWindow,
    Future<void> Function()? closeApp,
    Future<void> Function()? stopEngines,
    void Function(int code)? exitProcess,
    bool? exitsProcess,
    this.deadline = kShutdownDeadline,
    this.engineStopTimeout = kEngineStopTimeout,
  }) : // Closures, not tear-offs: `windowManager` is a lazy singleton whose
       // constructor installs a method-call handler, so naming it here would
       // reach for a platform channel even on paths that never use it — an
       // assertion failure under `flutter test`, where no binding exists.
       _hideWindow = hideWindow ?? (() => windowManager.hide()),
       _closeApp = closeApp ?? (() => windowManager.destroy()),
       _stopEngines = stopEngines ?? stopAllEngines,
       _exitProcess = exitProcess ?? exit,
       _exitsProcess = exitsProcess ?? Platform.isWindows;

  final Future<void> Function() _hideWindow;
  final Future<void> Function() _closeApp;
  final Future<void> Function() _stopEngines;
  final void Function(int code) _exitProcess;
  final bool _exitsProcess;

  /// Backstop for the whole teardown: past it, the process ends regardless.
  final Duration deadline;
  final Duration engineStopTimeout;

  /// The app's providers, once `main` has built them. Disposed by [run].
  ProviderContainer? container;

  /// Saves the window's position and size. Attached by `main` once the
  /// window-state service exists.
  Future<void> Function()? saveWindowState;

  /// A save still in flight after [saveWindowState]'s budget ran out, given a
  /// last moment to land before the process ends.
  Future<void> Function()? pendingWindowSave;

  /// Runs before anything else — for observers that must not react to the
  /// teardown itself, such as the window-fit check.
  void Function()? beforeTeardown;

  Future<void>? _teardown;
  Timer? _watchdog;

  /// Whether a teardown has begun. The app is on its way out from here.
  bool get isShuttingDown => _teardown != null;

  /// Tear the app down, once. Every caller gets the same future.
  ///
  /// Never throws and never hangs past [deadline]: nothing in a shutdown is
  /// important enough to stop the shutdown.
  Future<void> run() => _teardown ??= _runTeardown();

  Future<void> _runTeardown() async {
    AppLog.i('[Shutdown] closing');

    // The backstop, and the only promise this class can actually keep. If
    // the teardown — or, on macOS, the quit that follows it — is still going
    // when this fires, the process ends regardless. Never cancelled outside
    // tests: from here on the process is meant to end one way or another.
    _watchdog = Timer(deadline, () {
      AppLog.e('[Shutdown] deadline exceeded — forcing exit');
      _exitProcess(0);
    });

    try {
      beforeTeardown?.call();
    } catch (e) {
      AppLog.w('[Shutdown] could not prepare: $e');
    }

    // 1. Get off the screen. See the class doc: this is the symptom fix.
    //    On macOS the reply can lag behind the hide itself — ordering out the
    //    last window starts AppKit's own quit, which the main thread handles
    //    first — so running out of budget here is expected, not a failure.
    try {
      await _hideWindow().timeout(const Duration(milliseconds: 250));
    } on TimeoutException {
      AppLog.i('[Shutdown] window hide still settling — carrying on');
    } catch (e) {
      AppLog.w('[Shutdown] could not hide the window: $e');
    }

    // 2. Stop what we started, and remember where the window was. Neither
    //    depends on the other, so neither waits for the other.
    final save = saveWindowState;
    await Future.wait([
      _bounded('stop the engine', _stopEngines, engineStopTimeout),
      if (save != null)
        _bounded('save the window position', save, kWindowSaveTimeout),
    ]);

    // 3. Provider teardown, guarded. A synchronous throw out of `dispose()`
    //    must never trap someone in an app they have asked to leave. A throw
    //    inside an `onDispose` callback does not arrive here at all: Riverpod
    //    runs those guarded and reports them to the zone the container was
    //    built in, where `main` logs it as an uncaught error and carries on.
    try {
      container?.dispose();
    } catch (e, st) {
      AppLog.w('[Shutdown] provider teardown failed: $e\n$st');
    }

    // 4. A window save that overran its budget is still writing. Give it a
    //    last moment rather than letting the exit cut it off mid-file.
    final pending = pendingWindowSave;
    if (pending != null) {
      await _bounded(
        'finish the window-state save',
        pending,
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
  }

  /// The window's close button, ⌘W, Alt+F4, the taskbar's Close window.
  Future<void> closeFromWindow() async {
    await run();
    if (_exitsProcess) {
      _endProcess();
      return; // Only reached under test, where the exit is injected.
    }
    // macOS: hand over to AppKit's quit, which the app delegate lets through
    // at once now that the teardown is done.
    await _bounded('quit', _closeApp, const Duration(seconds: 1));
  }

  /// An app-level quit request from the framework — the path on Windows,
  /// and on macOS for a build whose app delegate does not hold the quit open
  /// itself.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await run();
    if (_exitsProcess) _endProcess();
    return AppExitResponse.exit;
  }

  /// Answer native code's request to get ready to quit — the macOS app
  /// delegate's, or the Windows runner's when the session is ending. The
  /// process is left running: the caller ends it once this answers.
  Future<bool> prepareToQuit() async {
    await run();
    return true;
  }

  void _endProcess() {
    _watchdog?.cancel();
    _exitProcess(0);
  }

  /// End the backstop. Tests only — a real teardown always ends the process.
  @visibleForTesting
  void cancelWatchdog() => _watchdog?.cancel();
}

/// Run [action] with a budget, and treat every failure as non-fatal.
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
