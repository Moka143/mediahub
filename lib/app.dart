import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/app_colors.dart';
import 'design/app_theme.dart';
import 'design/app_tokens.dart';
import 'design/app_typography.dart';
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

/// What the window shows while the app is still loading its credentials.
///
/// `main` shows the window before the Keychain / DPAPI read rather than
/// after it, and this is the frame it shows: the splash screen's backdrop
/// and wordmark, so the hand-over is seamless. Deliberately nothing that
/// needs a theme, bundled fonts, providers or a Navigator — none exist yet.
///
/// The read is usually instant. When it is not, it is almost always macOS
/// asking the user — a fresh, unsigned build is a stranger to the keychain
/// item — and that prompt can sit behind the window. After [hintDelay] the
/// placeholder says so, rather than leaving a blank window to wonder about.
class StartupPlaceholder extends StatefulWidget {
  const StartupPlaceholder({super.key});

  static const Duration hintDelay = Duration(seconds: 3);

  @override
  State<StartupPlaceholder> createState() => _StartupPlaceholderState();
}

class _StartupPlaceholderState extends State<StartupPlaceholder> {
  /// Half the splash screen's wordmark, which takes over from this one.
  static const double _wordmarkSize = 48;

  Timer? _hintTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _hintTimer = Timer(StartupPlaceholder.hintDelay, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = defaultTargetPlatform == TargetPlatform.macOS
        ? 'Waiting for access to your saved passwords. If macOS asks, '
              'allow MediaHub to use its keychain item.'
        : 'Loading your saved credentials…';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: AppType.ui(
          size: AppType.sizeBody,
          color: AppColors.fg2,
        ).copyWith(decoration: TextDecoration.none),
        textAlign: TextAlign.center,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.2),
              radius: 1.0,
              colors: [AppColors.bgSurfaceHi, AppColors.bgPage],
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'MediaHub',
                  style: AppType.serif(size: _wordmarkSize, height: 1.0),
                ),
                const SizedBox(height: AppSpacing.xxxl),
                const SizedBox(
                  width: AppIconSize.lg,
                  height: AppIconSize.lg,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.fg2),
                  ),
                ),
                if (_slow)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xxl),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: Text(hint),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
