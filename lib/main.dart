import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/settings_provider.dart';
import 'services/prefs_recovery.dart';
import 'services/startup_logger.dart';
import 'services/window_state_service.dart';
import 'utils/constants.dart';

void main() {
  // Top-level guard: a thrown exception before runApp() leaves a zombie
  // process with no window and no error visible to the user. Catch
  // everything, write it to disk, and exit cleanly so at least the user can
  // tell the app launched and failed instead of "did nothing".
  runZonedGuarded(_bootstrap, (error, stack) async {
    final log = await StartupLogger.open();
    await log.log('FATAL during startup: $error\n$stack');
    exit(1);
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  final log = await StartupLogger.open();
  await log.log('startup: WidgetsFlutterBinding ready');

  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await log.log('startup: window_manager ready');

  final prefsResult = await loadPrefsSafe(log);
  final sharedPreferences = prefsResult.prefs;
  if (prefsResult.recovered) {
    await log.log('startup: prefs were corrupted, reset to defaults');
  } else {
    await log.log('startup: prefs loaded');
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
  await log.log('startup: window shown');

  windowManager.addListener(windowStateService);

  await log.log('startup: runApp()');
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      ],
      child: const TorrentClientApp(),
    ),
  );
}
