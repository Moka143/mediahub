import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_torrent_client/screens/main_navigation_screen.dart';
import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../providers/settings_provider.dart';
import '../providers/tmdb_account_provider.dart';
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

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

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
    _controller.forward().whenComplete(() async {
      await Future.delayed(const Duration(milliseconds: 400));
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
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              goHome ? const MainNavigationScreen() : const OnboardingScreen(),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    });
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
            colors: [Color(0xFF1F1B17), AppColors.bgPage],
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
                  size: 96,
                  height: 1.0,
                  letterSpacing: -0.03,
                  color: AppColors.fg,
                ),
                const SizedBox(height: AppSpacing.md),
                const MonoLabel(
                  '— STREAM · DOWNLOAD · LIBRARY —',
                  color: AppColors.accent,
                  letterSpacing: 0.18,
                ),
                const SizedBox(height: AppSpacing.huge),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.fg3),
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
