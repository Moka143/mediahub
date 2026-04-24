import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/app_theme.dart';
import 'providers/settings_provider.dart';
import 'screens/splash_screen.dart';
import 'utils/constants.dart';

/// Global key for the root ScaffoldMessenger
/// Use this to show SnackBars that persist across navigation
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Global key for the root Navigator
/// Use this for navigation from anywhere in the app
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Main application widget
class TorrentClientApp extends ConsumerWidget {
  const TorrentClientApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      navigatorKey: rootNavigatorKey,
      home: const SplashScreen(),
    );
  }
}
