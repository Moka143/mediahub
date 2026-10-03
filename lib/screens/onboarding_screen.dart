import 'dart:async';

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
import '../services/app_logger.dart';
import '../utils/constants.dart';
import '../utils/error_messages.dart';
import '../utils/feedback_utils.dart';
import '../widgets/editorial/editorial.dart';
import 'main_navigation_screen.dart';
import 'settings/settings_validation.dart';
import 'settings/tmdb_token_check.dart';

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

  /// A well-formed token TMDB could not be asked about (offline, TMDB down).
  /// Offered with "Continue without checking" — the problem is the network,
  /// not the token, and a person without internet should not be locked out
  /// of their local library by it.
  String? _uncheckedToken;

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
      AppSnackBar.showError(
        context,
        message: 'Couldn\'t open your browser. The page is $url',
      );
    }
  }

  Future<void> _navigateToHome() async {
    final onboarding = ref.read(hasCompletedOnboardingProvider.notifier);
    await onboarding.markCompleted();
    if (!mounted) return;
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const MainNavigationScreen()),
      ),
    );
  }

  /// Check the pasted token with TMDB before saving it.
  ///
  /// It used to be saved unchecked, so a bad paste went straight through to
  /// a Home screen whose rows quietly failed to load, with nothing saying
  /// why. Now a token TMDB refuses never gets past this step.
  Future<void> _saveTokenAndAdvance() async {
    final value = _tokenController.text.trim();
    final formatError = tmdbTokenFormatError(value);
    if (formatError != null) {
      setState(() {
        _error = formatError;
        _uncheckedToken = null;
      });
      return;
    }
    final settings = ref.read(settingsProvider.notifier);
    final client = ref.read(tmdbTokenCheckServiceProvider);
    setState(() {
      _busy = true;
      _error = null;
      _uncheckedToken = null;
    });
    try {
      final check = await checkTmdbToken(client, value);
      if (!mounted) return;
      switch (check.verdict) {
        case TmdbTokenVerdict.accepted:
          // Saving flips the screen to step 2.
          await settings.setTmdbApiKey(value);
        case TmdbTokenVerdict.rejected:
          setState(() => _error = check.message);
        case TmdbTokenVerdict.unchecked:
          setState(() {
            _error = check.message;
            _uncheckedToken = value;
          });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveUncheckedToken() async {
    final token = _uncheckedToken;
    if (token == null) return;
    final settings = ref.read(settingsProvider.notifier);
    setState(() {
      _error = null;
      _uncheckedToken = null;
    });
    await settings.setTmdbApiKey(token);
  }

  Future<void> _startSignIn() async {
    final session = ref.read(tmdbSessionProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await session.beginSignIn();
      if (!mounted) return;
      setState(() => _pendingApprovalToken = token);
    } catch (e) {
      if (mounted) {
        setState(() => _error = friendlyErrorMessage(e, subject: 'TMDB'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeSignIn() async {
    final token = _pendingApprovalToken;
    if (token == null) return;
    final session = ref.read(tmdbSessionProvider.notifier);
    final favorites = ref.read(favoritesProvider.notifier);
    final watchlist = ref.read(watchlistProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.completeSignIn(token);
    } catch (e) {
      if (mounted) {
        final kind = classifyFailure(e);
        setState(() {
          _busy = false;
          _error = kind == FailureKind.offline || kind == FailureKind.timeout
              ? friendlyErrorMessage(e)
              : 'TMDB didn\'t confirm the sign-in. Approve MediaHub in the '
                    'browser page, then try again — or start over if that '
                    'page has expired.';
        });
      }
      return;
    }
    // Signed in. A list that fails to sync now syncs on the next launch, so
    // it is no reason to keep someone on the welcome screen.
    for (final sync in [
      () => favorites.syncFromTmdb(pushLocalFirst: true),
      () => watchlist.syncFromTmdb(pushLocalFirst: true),
    ]) {
      try {
        await sync();
      } catch (e) {
        AppLog.w('[Onboarding] first sync after sign-in failed: $e');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _navigateToHome();
  }

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
                const _Header(),
                const SizedBox(height: AppSpacing.xl),

                if (_pendingApprovalToken != null)
                  _ApprovalPendingCard(
                    busy: _busy,
                    onFinish: () => unawaited(_completeSignIn()),
                    onStartOver: () => unawaited(_startSignIn()),
                    onCancel: () => setState(() {
                      _pendingApprovalToken = null;
                      _error = null;
                    }),
                  )
                else if (!hasToken)
                  _Step1PasteToken(
                    controller: _tokenController,
                    obscure: _obscureToken,
                    onToggleObscure: () =>
                        setState(() => _obscureToken = !_obscureToken),
                    busy: _busy,
                    onSave: () => unawaited(_saveTokenAndAdvance()),
                    onOpenSignup: () => unawaited(_openUrl(_tmdbSignupUrl)),
                    onOpenApiPage: () => unawaited(_openUrl(_tmdbApiUrl)),
                  )
                else
                  _Step2SignInOrSkip(
                    busy: _busy,
                    onSignIn: () => unawaited(_startSignIn()),
                    onSkip: () => unawaited(_navigateToHome()),
                  ),

                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: AppType.body(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                  if (_uncheckedToken != null && !_busy)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: TextButton(
                        onPressed: () => unawaited(_saveUncheckedToken()),
                        child: const Text('Continue without checking'),
                      ),
                    ),
                ],

                const SizedBox(height: AppSpacing.lg),
                Text(
                  hasToken
                      ? 'You can sign in or out later in Settings → '
                            'Connection.'
                      : 'Your token is stored only on this computer.',
                  textAlign: TextAlign.center,
                  style: AppType.caption(),
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
  const _Header();

  /// The first-run wordmark, as large as the Home hero's title — above the
  /// type ramp's top step, [AppType.sizeDisplay].
  static const double _wordmarkSize = 64;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const MonoLabel(
          'Welcome to',
          color: AppColors.accent,
          letterSpacing: 0.18,
          size: AppType.sizeSmall,
        ),
        const SizedBox(height: 10),
        const SerifTitle(
          AppConstants.appName,
          size: _wordmarkSize,
          height: 1.0,
          letterSpacing: -0.02,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'A free TMDB account powers the catalog.',
          textAlign: TextAlign.center,
          style: AppType.ui(
            size: AppType.sizeLead,
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
    return _StepCard(
      stepNumber: 1,
      title: 'Paste your TMDB token',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'On TMDB\'s API settings page, copy the field labelled "API Read '
            'Access Token" — the long one that starts with eyJ… — and paste '
            'it below.',
            style: AppType.body(),
          ),
          const SizedBox(height: AppSpacing.md),

          // Quick links
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : onOpenApiPage,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open TMDB API settings'),
              ),
              TextButton.icon(
                onPressed: busy ? null : onOpenSignup,
                icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                label: const Text('No TMDB account? Create one'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // Token field
          TextField(
            controller: controller,
            autofocus: true,
            enabled: !busy,
            obscureText: obscure,
            enableSuggestions: false,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            onSubmitted: (_) => onSave(),
            decoration: InputDecoration(
              labelText: 'TMDB token',
              hintText: 'Starts with eyJ…',
              prefixIcon: const Icon(Icons.key_rounded),
              suffixIcon: IconButton(
                icon: Icon(
                  obscure
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded,
                ),
                tooltip: obscure ? 'Show token' : 'Hide token',
                onPressed: onToggleObscure,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Check & continue
          FilledButton.icon(
            onPressed: busy ? null : onSave,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            ),
            icon: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_forward_rounded),
            label: Text(busy ? 'Checking with TMDB…' : 'Continue'),
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
    return _StepCard(
      stepNumber: 2,
      title: 'Sign in to sync (optional)',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: AppColors.ok,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text('Token saved.', style: AppType.bodyStrong()),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Sign in with TMDB in your browser to sync your favorites and '
            'watchlist across devices. You can skip this and just browse — '
            'your favorites then stay on this computer only.',
            style: AppType.body(),
          ),
          const SizedBox(height: AppSpacing.md),

          FilledButton.icon(
            onPressed: busy ? null : onSignIn,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
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
            child: const Text('Skip — use MediaHub without an account'),
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
  final bool busy;
  final VoidCallback onFinish;
  final VoidCallback onStartOver;
  final VoidCallback onCancel;

  const _ApprovalPendingCard({
    required this.busy,
    required this.onFinish,
    required this.onStartOver,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return _StepCard(
      stepNumber: 2,
      title: 'Waiting for you to approve',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A TMDB page opened in your browser. Log in if needed, click '
            'Approve, then come back here.',
            style: AppType.body(),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: busy ? null : onFinish,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            ),
            icon: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: const Text('I\'ve approved it'),
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            children: [
              // The approval page expires, and a denied request fails the
              // same way every time; asking again needs a new request.
              TextButton(
                onPressed: busy ? null : onStartOver,
                child: const Text('Start over'),
              ),
              TextButton(
                onPressed: busy ? null : onCancel,
                child: const Text('Cancel'),
              ),
            ],
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
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.lineStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            label: 'Step $stepNumber, $title',
            excludeSemantics: true,
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$stepNumber',
                    style: AppType.bodyStrong(color: AppColors.onAccent),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: AppType.ui(
                      size: AppType.sizeSubhead,
                      color: AppColors.fg,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}
