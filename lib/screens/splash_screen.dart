import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../providers/settings_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../screens/main_navigation_screen.dart';
import '../widgets/editorial/editorial.dart';
import 'onboarding_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  /// The logo's elastic entrance. The splash leaves when it ends, so this is
  /// also how long the splash is on screen — not just an animation speed.
  static const Duration _entranceDuration = Duration(milliseconds: 1200);

  /// A beat with the logo at rest before leaving, so it is seen settled.
  static const Duration _holdDuration = Duration(milliseconds: 400);

  /// The wordmark is the splash's only content — above the type ramp's top
  /// step, `AppType.sizeDisplay`.
  static const double _wordmarkSize = 96;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(vsync: this, duration: _entranceDuration);

    _scaleAnimation = Tween<double>(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut));

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
      ),
    );

    // Navigate as soon as the entrance animation finishes + a short hold so
    // users actually see the logo in its final state. Previously we waited a
    // fixed 2.5 s regardless of animation progress, which felt sluggish.
    unawaited(_controller.forward().whenComplete(_leave));
  }

  Future<void> _leave() async {
    await Future<void>.delayed(_holdDuration);
    if (!mounted) return;
    // Routing rules:
    //   - If the user is already TMDB-signed-in (from a previous version
    //     or session), skip onboarding regardless of the flag — they've
    //     clearly been past the sign-in invitation before.
    //   - Else, show onboarding when there's no key OR when the user
    //     hasn't been past it yet (so existing users with just an API
    //     key get the one-time sign-in invitation).
    //   - Otherwise, home.
    final isSignedIn = ref.read(isTmdbSignedInProvider);
    final hasOnboarded = ref.read(hasCompletedOnboardingProvider);
    final hasKey = ref.read(hasTmdbApiKeyProvider);
    final goHome = isSignedIn || (hasOnboarded && hasKey);
    unawaited(
      Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) =>
              goHome ? const MainNavigationScreen() : const OnboardingScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: AppDuration.slow,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPage,
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.2),
            radius: 1.0,
            colors: [AppColors.bgSurfaceHi, AppColors.bgPage],
          ),
        ),
        child: Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Opacity(
                opacity: _fadeAnimation.value,
                child: Transform.scale(
                  scale: _scaleAnimation.value,
                  child: child,
                ),
              );
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SerifTitle(
                  'MediaHub',
                  size: _wordmarkSize,
                  height: 1.0,
                  letterSpacing: -0.03,
                  color: AppColors.fg,
                ),
                const SizedBox(height: AppSpacing.md),
                const MonoLabel(
                  '— Stream · Download · Library —',
                  color: AppColors.accent,
                  letterSpacing: 0.18,
                ),
                const SizedBox(height: AppSpacing.huge),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.fg2),
                    semanticsLabel: 'Starting',
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
