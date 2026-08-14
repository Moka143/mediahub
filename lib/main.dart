import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/settings_provider.dart';
import 'services/app_logger.dart';
import 'services/prefs_recovery.dart';
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

  final windowStateService = WindowStateService(sharedPreferences);
  final savedState = windowStateService.loadState();

  final initialSize = savedState.bounds != null
      ? Size(savedState.bounds!.width, savedState.bounds!.height)
      : const Size(1100, 720);

  final windowOptions = WindowOptions(
    size: initialSize,
    minimumSize: const Size(
      AppConstants.minWindowWidth,
      AppConstants.minWindowHeight,
    ),
    center: savedState.bounds == null,
    title: AppConstants.appName,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    if (savedState.bounds != null) {
      await windowManager.setBounds(savedState.bounds);
    }
    if (savedState.maximized) {
      await windowManager.maximize();
    }
    await windowManager.show();
    await windowManager.focus();
  });
  AppLog.i('[Startup] window shown');

  windowManager.addListener(windowStateService);

  AppLog.i('[Startup] runApp()');
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      ],
      child: const MediaHubApp(),
    ),
  );
}
