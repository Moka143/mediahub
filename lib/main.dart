import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/settings_provider.dart';
import 'providers/startup_notices_provider.dart';
import 'services/app_logger.dart';
import 'services/app_shutdown.dart';
import 'services/prefs_recovery.dart';
import 'services/secret_store.dart';
import 'services/window_fit_service.dart';
import 'services/window_state_service.dart';
import 'utils/constants.dart';

/// Set once the real app is on screen. Until then an uncaught error means the
/// app never started; after it, it is one bug in a running app.
bool _bootstrapped = false;

/// The channel native code uses to hold a quit until the Dart side has torn
/// down: the macOS app delegate (`macos/Runner/AppDelegate.swift`) and, on a
/// Windows sign-out or shutdown, the runner window
/// (`windows/runner/flutter_window.cpp`).
const MethodChannel _appExitChannel = MethodChannel('mediahub/app_exit');

void main() {
  // The bootstrap's own future is not awaited by anything: whatever it
  // throws lands in the zone handler below.
  runZonedGuarded(
    () => unawaited(_bootstrap()),
    (error, stack) => unawaited(
      reportUncaughtError(
        error,
        stack,
        bootstrapping: !_bootstrapped,
        exitProcess: exit,
      ),
    ),
  );
}

/// What to do with an error nothing caught.
///
/// **While bootstrapping** — before the app is on screen — it is fatal: a
/// throw before `runApp()` leaves a process with no window and no visible
/// error. Log it and exit, so at least the user can tell the app launched and
/// failed instead of "did nothing".
///
/// **Afterwards**, log it and keep running. This used to exit for the whole
/// lifetime of the app, labelled as a startup failure, which turned every
/// stray async error — a widget that used its `ref` after being closed — into
/// the app silently vanishing.
@visibleForTesting
Future<void> reportUncaughtError(
  Object error,
  StackTrace stack, {
  required bool bootstrapping,
  required void Function(int code) exitProcess,
}) async {
  if (!bootstrapping) {
    AppLog.e('[Uncaught] $error\n$stack');
    return;
  }
  // init() is idempotent — this only does work when the crash happened before
  // _bootstrap reached its own call, and it never reopens an already-open log.
  await AppLog.init();
  AppLog.e('[Startup] FATAL during startup: $error\n$stack');
  try {
    await AppLog.idle.timeout(kLogFlushTimeout);
  } catch (_) {
    // Exiting matters more than the last line.
  }
  exitProcess(1);
}

/// Send the framework's own error reports to the log as well.
///
/// Build and layout exceptions never reach the zone: the framework catches
/// them and calls [FlutterError.onError], which in a release build printed
/// to a console nobody has. Errors in callbacks the engine runs outside our
/// zone go to [PlatformDispatcher.onError].
void _routeFrameworkErrorsToLog() {
  FlutterError.onError = (details) {
    AppLog.e(
      '[Uncaught] ${details.exceptionAsString()}\n${details.stack ?? ''}',
    );
    if (kDebugMode) FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.e('[Uncaught] $error\n$stack');
    return true;
  };
}

/// Hook every way the app can be told to quit up to [shutdown].
void _wireExitPaths(AppShutdown shutdown) {
  // Windows — and any build whose app delegate does not hold the quit open.
  WidgetsBinding.instance.addObserver(shutdown);

  // macOS: ⌘Q, Dock → Quit, logout, AppleScript `quit`, and the quit AppKit
  // starts itself when the last window is hidden. Windows: signing out or
  // shutting down, which the framework does not report.
  _appExitChannel.setMethodCallHandler((call) async {
    if (call.method == 'prepareToQuit') return shutdown.prepareToQuit();
    throw MissingPluginException('mediahub/app_exit: ${call.method}');
  });

  // `kill`, a logout that gave up waiting, Ctrl-C in a terminal. Not on
  // Windows, which has no SIGTERM to watch.
  if (!Platform.isWindows) {
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signal.watch().listen((_) {
        AppLog.i('[Shutdown] received $signal');
        unawaited(shutdown.run().whenComplete(() => exit(0)));
      });
    }
  }
}

/// Work areas of the connected displays, in the units window_manager uses
/// for the window's bounds — see [WindowStateService.toWindowSpace].
///
/// "Work area" rather than full bounds throughout: it excludes the taskbar
/// (and the macOS menu bar and dock), which is what actually determines
/// whether a window can be seen and grabbed.
///
/// Returns empty lists when the platform cannot be asked. Callers treat that
/// as "no opinion" and keep whatever was saved, rather than discarding a
/// perfectly good window position because a display query failed.
Future<({List<Rect> workAreas, Rect? primaryWorkArea})>
_displayGeometry() async {
  final windowScale = Platform.isWindows
      ? PlatformDispatcher.instance.views.first.devicePixelRatio
      : 1.0;
  Rect workAreaOf(Display d) => WindowStateService.toWindowSpace(
    (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size),
    displayScale: Platform.isWindows ? (d.scaleFactor ?? 1).toDouble() : 1.0,
    windowScale: windowScale,
  );

  try {
    final all = await screenRetriever.getAllDisplays();
    final primary = await screenRetriever.getPrimaryDisplay();
    return (
      workAreas: [for (final d in all) workAreaOf(d)],
      primaryWorkArea: workAreaOf(primary),
    );
  } catch (e) {
    AppLog.w('[Startup] could not enumerate displays ($e)');
    return (workAreas: const <Rect>[], primaryWorkArea: null);
  }
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.init();
  _routeFrameworkErrorsToLog();
  AppLog.i('[Startup] WidgetsFlutterBinding ready');

  // Wired before anything can start an engine, so no quit — however early —
  // can skip stopping it.
  final shutdown = AppShutdown();
  _wireExitPaths(shutdown);

  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  AppLog.i('[Startup] window_manager ready');

  final prefsResult = await loadPrefsSafe();
  final sharedPreferences = prefsResult.prefs;
  if (prefsResult.recovered) {
    AppLog.w('[Startup] prefs were corrupted, reset to defaults');
  } else {
    AppLog.i('[Startup] prefs loaded');
  }

  final windowStateService = WindowStateService(
    sharedPreferences,
    onCloseRequested: shutdown.closeFromWindow,
  );
  shutdown
    ..saveWindowState = windowStateService.saveForClose
    ..pendingWindowSave = (() => windowStateService.pendingSave);

  // Ask the OS what screens exist before trusting the saved position: a
  // window last closed on a monitor that has since been unplugged would
  // otherwise be restored into empty space, visible to Windows and to nobody
  // else.
  final displays = await _displayGeometry();
  final savedState = windowStateService.loadStateFor(displays.workAreas);

  // Two different minimums, on purpose. `minimumSize` is what Windows will
  // enforce as `ptMinTrackSize` *in physical pixels* — window_manager
  // multiplies it by the monitor's scale — so it has to stay small enough that
  // the window can still fit a high-DPI panel. `designFloor` is what the
  // layout wants, and it is only ever a preference — `UiScale` covers the gap
  // between the two.
  const minimumSize = Size(
    AppConstants.hardMinWindowWidth,
    AppConstants.hardMinWindowHeight,
  );
  const designFloor = Size(
    AppConstants.minWindowWidth,
    AppConstants.minWindowHeight,
  );
  const preferredSize = Size(1100, 720);

  final initialSize = savedState.bounds != null
      ? Size(savedState.bounds!.width, savedState.bounds!.height)
      : displays.primaryWorkArea == null
      ? preferredSize
      : WindowStateService.fitToWorkArea(
          preferredSize,
          displays.primaryWorkArea!.size,
          designFloor,
        );

  final windowOptions = WindowOptions(
    size: initialSize,
    minimumSize: minimumSize,
    center: savedState.bounds == null,
    title: AppConstants.appName,
  );

  // Deliberately not using waitUntilReadyToShow's callback parameter: it is
  // typed VoidCallback and invoked without await, so an async callback's
  // future is dropped and the rest of main() races the window setup.
  await windowManager.waitUntilReadyToShow(windowOptions);
  if (savedState.bounds != null) {
    // Saved bounds were measured on whichever display the window was last
    // closed on. Reopening on a display with less room would otherwise apply
    // a size the screen cannot hold.
    await windowManager.setBounds(
      WindowStateService.clampToWorkArea(
        savedState.bounds!,
        displays.workAreas,
      ),
    );
  }
  if (savedState.maximized) {
    await windowManager.maximize();
  }

  // Show the window before the slow part. The Keychain / DPAPI read below can
  // take several seconds — 7.8 s on the first launch of a new build, while
  // macOS re-checks the signature — and the window used to stay hidden for
  // all of it. A painted frame first, so it does not appear blank.
  runApp(const StartupPlaceholder());
  try {
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 500),
    );
  } catch (_) {
    // Showing the window matters more than what is in its first frame.
  }
  await windowManager.show();
  await windowManager.focus();
  AppLog.i('[Startup] window shown');

  windowManager.addListener(windowStateService);

  // Watch for the window being dragged onto a display with a different scale.
  // The layout reflows on its own (UiScale reads the new MediaQuery), but the
  // window can be left physically larger than the new monitor's work area.
  final windowFit = WindowFitService()..start();
  shutdown.beforeTeardown = windowFit.stop;

  // Every close of the window comes to us — WindowStateService hands it to
  // the shutdown — instead of the native side closing it in the same breath.
  await windowManager.setPreventClose(true);

  // Reads the Keychain / DPAPI once, and moves any credentials an older
  // build left in shared_preferences. Done before the app proper because the
  // notifiers that need these values build synchronously.
  final secretStore = await SecretStore.open(sharedPreferences);
  AppLog.i('[Startup] secret store ready');
  if (shutdown.isShuttingDown) return; // Closed while we were waiting.

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      secretStoreProvider.overrideWithValue(secretStore),
      prefsWereResetProvider.overrideWithValue(prefsResult.recovered),
    ],
  );
  shutdown.container = container;

  AppLog.i('[Startup] runApp()');
  runApp(
    UncontrolledProviderScope(container: container, child: const MediaHubApp()),
  );
  _bootstrapped = true;
}
