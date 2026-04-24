import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/settings_provider.dart';
import 'services/window_state_service.dart';
import 'utils/constants.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize media_kit for video playback
  MediaKit.ensureInitialized();

  // Initialize window manager for desktop
  await windowManager.ensureInitialized();

  // Load SharedPreferences early so we can read saved window bounds.
  final sharedPreferences = await SharedPreferences.getInstance();
  final windowStateService = WindowStateService(sharedPreferences);
  final savedState = windowStateService.loadState();

  // Use the saved size if available; otherwise a conservative default that
  // fits on 1366x768 laptops without pushing the title bar off-screen when
  // the user maximizes.
  final initialSize = savedState.bounds != null
      ? Size(savedState.bounds!.width, savedState.bounds!.height)
      : const Size(1100, 720);

  final windowOptions = WindowOptions(
    size: initialSize,
    minimumSize: const Size(
      AppConstants.minWindowWidth,
      AppConstants.minWindowHeight,
    ),
    // Only center when we have no saved position — otherwise setBounds below
    // will restore the previous placement.
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

  // Start persisting window state for future launches.
  windowManager.addListener(windowStateService);

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      ],
      child: const TorrentClientApp(),
    ),
  );
}
