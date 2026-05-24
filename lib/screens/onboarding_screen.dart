import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../providers/favorites_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/watchlist_provider.dart';
import '../utils/constants.dart';
import '../utils/feedback_utils.dart';
import '../widgets/editorial/editorial.dart';
import 'main_navigation_screen.dart';

/// First-run screen.
///
/// Two clear steps:
///   1. Paste your TMDB Read Access Token (one-time, from your TMDB
///      account's API settings page).
///   2. Optionally sign in via TMDB browser OAuth to sync your favorites
///      and watchlist — or skip and just browse locally.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _tokenController = TextEditingController();
  bool _obscureToken = true;
  bool _busy = false;
  String? _pendingApprovalToken;
  String? _error;

  static final Uri _tmdbSignupUrl = Uri.parse(
    'https://www.themoviedb.org/signup',
  );
  static final Uri _tmdbApiUrl = Uri.parse(
    'https://www.themoviedb.org/settings/api',
  );

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _openUrl(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      AppSnackBar.showError(context, message: 'Could not open $url');
    }
  }

  Future<void> _navigateToHome() async {
    await ref.read(hasCompletedOnboardingProvider.notifier).markCompleted();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
    );
  }

  Future<void> _saveTokenAndAdvance() async {
    final value = _tokenController.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Please paste your token first');
      return;
    }
    if (!value.startsWith('eyJ')) {
      setState(
        () => _error =
            'That doesn\'t look right. Copy the "API Read Access Token" '
            '(starts with "eyJ…") from your TMDB settings page.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(settingsProvider.notifier).setTmdbApiKey(value);
      // Don't navigate yet — let the screen rebuild and show Step 2.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startSignIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await ref.read(tmdbSessionProvider.notifier).beginSignIn();
      if (!mounted) return;
      setState(() => _pendingApprovalToken = token);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeSignIn() async {
    final token = _pendingApprovalToken;
    if (token == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(tmdbSessionProvider.notifier).completeSignIn(token);
      await ref
          .read(favoritesProvider.notifier)
          .syncFromTmdb(pushLocalFirst: true);
      await ref
          .read(watchlistProvider.notifier)
          .syncFromTmdb(pushLocalFirst: true);
      if (!mounted) return;
      _navigateToHome();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _skipSignIn() => _navigateToHome();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasToken = ref.watch(hasTmdbApiKeyProvider);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(theme: theme),
                const SizedBox(height: AppSpacing.xl),

                if (_pendingApprovalToken != null)
                  _ApprovalPendingCard(
                    theme: theme,
                    busy: _busy,
                    onFinish: _completeSignIn,
                    onCancel: () =>
                        setState(() => _pendingApprovalToken = null),
                  )
                else if (!hasToken)
                  _Step1PasteToken(
                    controller: _tokenController,
                    obscure: _obscureToken,
                    onToggleObscure: () =>
                        setState(() => _obscureToken = !_obscureToken),
                    busy: _busy,
                    onSave: _saveTokenAndAdvance,
                    onOpenSignup: () => _openUrl(_tmdbSignupUrl),
                    onOpenApiPage: () => _openUrl(_tmdbApiUrl),
                  )
                else
                  _Step2SignInOrSkip(
                    busy: _busy,
                    onSignIn: _startSignIn,
                    onSkip: _skipSignIn,
                  ),

                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.6,
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: AppSpacing.lg),
                Text(
                  hasToken
                      ? 'You can sign in (or out) later from Settings → '
                            'TMDB Account.'
                      : 'Your token is stored only on this device.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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

class _Header extends StatelessWidget {
  final ThemeData theme;
  const _Header({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const MonoLabel(
          'WELCOME TO',
          color: AppColors.accent,
          letterSpacing: 0.18,
          size: 11,
        ),
        const SizedBox(height: 10),
        SerifTitle(
          AppConstants.appName,
          size: 64,
          height: 1.0,
          letterSpacing: -0.02,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'A free TMDB account powers the catalog.',
          textAlign: TextAlign.center,
          style: AppType.ui(
            size: 14,
            color: AppColors.fg1,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// STEP 1 — paste your TMDB token
// ============================================================================

class _Step1PasteToken extends StatelessWidget {
  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onOpenSignup;
  final VoidCallback onOpenApiPage;

  const _Step1PasteToken({
    required this.controller,
    required this.obscure,
    required this.onToggleObscure,
    required this.busy,
    required this.onSave,
    required this.onOpenSignup,
    required this.onOpenApiPage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StepCard(
      stepNumber: 1,
      title: 'Paste your TMDB token',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'On TMDB\'s API settings page, copy the field labelled '
            '"API Read Access Token" (the long one starting with "eyJ…") '
            'and paste it below.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),

          // Quick links
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onOpenApiPage,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Open TMDB API page'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              TextButton.icon(
                onPressed: busy ? null : onOpenSignup,
                icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                label: const Text('No account?'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // Token field
          TextField(
            controller: controller,
            autofocus: true,
            obscureText: obscure,
            enableSuggestions: false,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            onSubmitted: (_) => onSave(),
            decoration: InputDecoration(
              labelText: 'Read Access Token',
              hintText: 'eyJhbGciOiJIUzI1NiJ9…',
              prefixIcon: const Icon(Icons.key_rounded),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                  obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                ),
                tooltip: obscure ? 'Show' : 'Hide',
                onPressed: onToggleObscure,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Save & continue
          FilledButton.icon(
            onPressed: busy ? null : onSave,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_forward_rounded),
            label: const Text('Continue'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// STEP 2 — sign in to sync, or skip
// ============================================================================

class _Step2SignInOrSkip extends StatelessWidget {
  final bool busy;
  final VoidCallback onSignIn;
  final VoidCallback onSkip;

  const _Step2SignInOrSkip({
    required this.busy,
    required this.onSignIn,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _StepCard(
      stepNumber: 2,
      title: 'Sign in to sync (optional)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                color: theme.colorScheme.primary,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                'Token saved.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Sign in with TMDB in your browser to sync your favorites and '
            'watchlist across devices. You can skip this and just browse '
            'locally — your favorites will stay on this machine only.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),

          FilledButton.icon(
            onPressed: busy ? null : onSignIn,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: const Text('Sign in with TMDB'),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextButton(
            onPressed: busy ? null : onSkip,
            child: const Text('Skip — use locally only'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Approval-pending card (between step 2 sign-in click and browser approval)
// ============================================================================

class _ApprovalPendingCard extends StatelessWidget {
  final ThemeData theme;
  final bool busy;
  final VoidCallback onFinish;
  final VoidCallback onCancel;

  const _ApprovalPendingCard({
    required this.theme,
    required this.busy,
    required this.onFinish,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return _StepCard(
      stepNumber: 2,
      title: 'Waiting for browser approval',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A TMDB authorization page should have opened in your browser. '
            'Log in if needed, click Approve, then come back here.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: busy ? null : onFinish,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: const Text("I've approved it"),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextButton(
            onPressed: busy ? null : onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Reusable step card — adds the numbered chip + title
// ============================================================================

class _StepCard extends StatelessWidget {
  final int stepNumber;
  final String title;
  final Widget child;

  const _StepCard({
    required this.stepNumber,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$stepNumber',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}
