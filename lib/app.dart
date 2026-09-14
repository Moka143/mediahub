import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/app_theme.dart';
import 'design/ui_scale.dart';
import 'screens/splash_screen.dart';
import 'utils/constants.dart';

/// Global key for the root ScaffoldMessenger
/// Use this to show SnackBars that persist across navigation
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Global key for the root Navigator
/// Use this for navigation from anywhere in the app
final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Main application widget
class MediaHubApp extends ConsumerWidget {
  const MediaHubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      // Give the layout back the viewport it was designed for.
      //
      // On Windows the logical viewport is the panel divided by the display
      // scale, so "1920x1080 at 250%" is a 768x432 viewport — smaller than the
      // 800x600 this design assumes, smaller than the 900px sidebar gate, and
      // smaller than several fixed row heights. UiScale scales the whole UI
      // down in that case and hands every widget below it an 800x600-or-larger
      // MediaQuery, so nothing downstream needs to know about DPI.
      //
      // It is a no-op — it literally returns `child` — at any viewport of
      // 800x600 or more, which is every window at 100% and 150% display scale.
      // Placed on `builder` rather than around `home` so it also wraps
      // dialogs, the root overlay and every pushed route.
      builder: (context, child) => UiScale(
        designFloor: const Size(
          AppConstants.minWindowWidth,
          AppConstants.minWindowHeight,
        ),
        child: child!,
      ),
      // MediaHub ships dark-only — the editorial palette doesn't have a
      // light variant. We pin themeMode to dark rather than honouring
      // system preference so users on light-mode OS don't get a black-
      // text-on-black surface.
      themeMode: ThemeMode.dark,
      darkTheme: buildDarkTheme(),
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      navigatorKey: rootNavigatorKey,
      home: const SplashScreen(),
    );
  }
}
