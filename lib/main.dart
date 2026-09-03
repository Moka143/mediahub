import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/settings_provider.dart';
import 'services/app_logger.dart';
import 'services/prefs_recovery.dart';
import 'services/secret_store.dart';
import 'services/window_state_service.dart';
import 'utils/constants.dart';

void main() {
  // Top-level guard: a thrown exception before runApp() leaves a zombie
  // process with no window and no error visible to the user. Catch
  // everything, write it to disk, and exit cleanly so at least the user can
  // tell the app launched and failed instead of "did nothing".
  runZonedGuarded(_bootstrap, (error, stack) async {
    // init() is idempotent — this only does work when the crash happened
    // before _bootstrap reached its own call. Crucially it no longer reopens
    // an already-open log, which used to re-run the size check and could
    // delete the very breadcrumbs leading up to this fatal.
    await AppLog.init();
    AppLog.e('[Startup] FATAL during startup: $error\n$stack');
    await AppLog.idle;
    exit(1);
  });
}

/// Work areas of the connected displays, in logical pixels.
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
  Rect workAreaOf(Display d) =>
      (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);

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
  AppLog.i('[Startup] WidgetsFlutterBinding ready');

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

  // Reads the Keychain / DPAPI once, and moves any credentials an older
  // build left in shared_preferences. Done here because the notifiers that
  // need these values build synchronously.
  final secretStore = await SecretStore.open(sharedPreferences);
  AppLog.i('[Startup] secret store ready');

  final windowStateService = WindowStateService(sharedPreferences);

  // Ask the OS what screens exist before trusting the saved position: a
  // window last closed on a monitor that has since been unplugged would
  // otherwise be restored into empty space, visible to Windows and to nobody
  // else.
  final displays = await _displayGeometry();
  final savedState = windowStateService.loadStateFor(displays.workAreas);

  const minimumSize = Size(
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
          minimumSize,
        );

  final windowOptions = WindowOptions(
    size: initialSize,
    minimumSize: minimumSize,
    center: savedState.bounds == null,
    title: AppConstants.appName,
  );

  // Deliberately not using waitUntilReadyToShow's callback parameter: it is
  // typed VoidCallback and invoked without await, so an async callback's
  // future is dropped and the rest of main() races the window setup. Doing
  // the same work here keeps it ordered.
  await windowManager.waitUntilReadyToShow(windowOptions);
  if (savedState.bounds != null) {
    await windowManager.setBounds(savedState.bounds);
  }
  if (savedState.maximized) {
    await windowManager.maximize();
  }
  await windowManager.show();
  await windowManager.focus();
  AppLog.i('[Startup] window shown');

  windowManager.addListener(windowStateService);

  // Required for the close-time save to actually land. Without it the native
  // side emits `close` and tears the window down in the same message, so an
  // async save never resumes. WindowStateService.onWindowClose owns the
  // teardown from here — it always destroys, even if saving fails.
  await windowManager.setPreventClose(true);

  AppLog.i('[Startup] runApp()');
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
        secretStoreProvider.overrideWithValue(secretStore),
      ],
      child: const MediaHubApp(),
    ),
  );
}
