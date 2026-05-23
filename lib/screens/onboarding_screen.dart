import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/app_tokens.dart';
import '../providers/favorites_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/watchlist_provider.dart';
import '../utils/constants.dart';
import '../utils/feedback_utils.dart';
import 'main_navigation_screen.dart';

/// First-run screen.
///
/// Leads with TMDB browser sign-in (so the user can sync favorites and
/// watchlist across devices) instead of a raw API-key paste. When a bundled
/// API key is present (set at build time via `--dart-define=TMDB_API_KEY=…`)
/// users can also skip sign-in entirely and just browse locally.
///
/// The API-key paste field stays available under an "Advanced" expander —
/// useful when there's no bundled key, or when the user wants to use their
/// own quota.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _keyController = TextEditingController();
  bool _obscureKey = true;
  bool _showAdvanced = false;
  bool _busy = false;
  String? _pendingToken;
  String? _error;

  static final Uri _tmdbSignupUrl = Uri.parse(
    'https://www.themoviedb.org/signup',
  );
  static final Uri _tmdbApiUrl = Uri.parse(
    'https://www.themoviedb.org/settings/api',
  );

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _openUrl(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      AppSnackBar.showError(context, message: 'Could not open $url');
    }
  }

  Future<void> _navigateToHome() async {
    // Stamp the onboarding flag so splash doesn't route here again next launch.
    await ref.read(hasCompletedOnboardingProvider.notifier).markCompleted();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainNavigationScreen()),
    );
  }

  Future<void> _startSignIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await ref.read(tmdbSessionProvider.notifier).beginSignIn();
      if (!mounted) return;
      setState(() => _pendingToken = token);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeSignIn() async {
    final token = _pendingToken;
    if (token == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(tmdbSessionProvider.notifier).completeSignIn(token);
      // Pull TMDB lists so the app opens already populated.
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

  Future<void> _saveApiKeyAndContinue() async {
    final value = _keyController.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'API key cannot be empty');
      return;
    }
    if (value.length < 16) {
      setState(() => _error = 'Key looks too short');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(settingsProvider.notifier).setTmdbApiKey(value);
      if (!mounted) return;
      _navigateToHome();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _skip() {
    // Bundled key is in place; user can sync later via Settings.
    _navigateToHome();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasKey = ref.watch(hasTmdbApiKeyProvider);
    final usingBundled = ref.watch(isUsingBundledTmdbKeyProvider);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  child: Image.asset('assets/icon.png', width: 96, height: 96),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Welcome to ${AppConstants.appName}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _IntroCopy(hasKey: hasKey, theme: theme),
                const SizedBox(height: AppSpacing.xl),

                if (_pendingToken != null)
                  _PendingApprovalCard(
                    theme: theme,
                    busy: _busy,
                    onFinish: _completeSignIn,
                    onCancel: () => setState(() => _pendingToken = null),
                  )
                else if (hasKey) ...[
                  _PrimarySignInButton(busy: _busy, onPressed: _startSignIn),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    onPressed: _busy ? null : _skip,
                    child: const Text('Skip — use locally only'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _AdvancedSection(
                    expanded: _showAdvanced,
                    onToggle: () =>
                        setState(() => _showAdvanced = !_showAdvanced),
                    controller: _keyController,
                    obscure: _obscureKey,
                    onObscureToggle: () =>
                        setState(() => _obscureKey = !_obscureKey),
                    busy: _busy,
                    onSave: _saveApiKeyAndContinue,
                    onOpenKeyPage: () => _openUrl(_tmdbApiUrl),
                    onOpenSignup: () => _openUrl(_tmdbSignupUrl),
                    bundledKeyInUse: usingBundled,
                  ),
                ] else ...[
                  // No key at all — releases shipped without --dart-define
                  // OR a dev source build. Paste flow is primary here.
                  _ApiKeyEntry(
                    controller: _keyController,
                    obscure: _obscureKey,
                    onObscureToggle: () =>
                        setState(() => _obscureKey = !_obscureKey),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openUrl(_tmdbSignupUrl),
                          icon: const Icon(Icons.person_add_alt_rounded),
                          label: const Text('Create account'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openUrl(_tmdbApiUrl),
                          icon: const Icon(Icons.key_rounded),
                          label: const Text('Get key'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton(
                    onPressed: _busy ? null : _saveApiKeyAndContinue,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Continue'),
                  ),
                ],

                if (_error != null) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Text(
                  hasKey
                      ? 'You can sign in later from Settings → TMDB Account.'
                      : 'Your key is stored only on this device.',
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

class _IntroCopy extends StatelessWidget {
  final bool hasKey;
  final ThemeData theme;

  const _IntroCopy({required this.hasKey, required this.theme});

  @override
  Widget build(BuildContext context) {
    final text = hasKey
        ? 'Sign in with TMDB to sync your favorites and watchlist across '
              'devices. You can also skip and just browse locally.'
        : 'To discover shows and movies, paste your free TMDB API key.';
    return Text(
      text,
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _PrimarySignInButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onPressed;

  const _PrimarySignInButton({required this.busy, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: busy ? null : onPressed,
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
    );
  }
}

class _PendingApprovalCard extends StatelessWidget {
  final ThemeData theme;
  final bool busy;
  final VoidCallback onFinish;
  final VoidCallback onCancel;

  const _PendingApprovalCard({
    required this.theme,
    required this.busy,
    required this.onFinish,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.open_in_browser_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Approve access in your browser',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'A TMDB authorization page should have opened. After approving, '
            'come back here and tap the button below.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: busy ? null : onFinish,
            icon: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: const Text("I've approved it — finish sign-in"),
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

class _AdvancedSection extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onObscureToggle;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onOpenKeyPage;
  final VoidCallback onOpenSignup;
  final bool bundledKeyInUse;

  const _AdvancedSection({
    required this.expanded,
    required this.onToggle,
    required this.controller,
    required this.obscure,
    required this.onObscureToggle,
    required this.busy,
    required this.onSave,
    required this.onOpenKeyPage,
    required this.onOpenSignup,
    required this.bundledKeyInUse,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Advanced: use your own TMDB API key',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (bundledKeyInUse)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Text(
                        'Currently using the bundled key. Paste your own '
                        'below if you prefer your personal quota.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  _ApiKeyEntry(
                    controller: controller,
                    obscure: obscure,
                    onObscureToggle: onObscureToggle,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: onOpenSignup,
                          icon: const Icon(
                            Icons.person_add_alt_rounded,
                            size: 18,
                          ),
                          label: const Text('Create account'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: onOpenKeyPage,
                          icon: const Icon(Icons.key_rounded, size: 18),
                          label: const Text('Get key'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton.tonal(
                    onPressed: busy ? null : onSave,
                    child: const Text('Save key & continue'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ApiKeyEntry extends StatelessWidget {
  final TextEditingController controller;
  final bool obscure;
  final VoidCallback onObscureToggle;

  const _ApiKeyEntry({
    required this.controller,
    required this.obscure,
    required this.onObscureToggle,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enableSuggestions: false,
      autocorrect: false,
      textInputAction: TextInputAction.done,
      inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
      decoration: InputDecoration(
        labelText: 'TMDB API Key (v3 auth)',
        hintText: 'e.g. 0123456789abcdef…',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(
            obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
          ),
          tooltip: obscure ? 'Show' : 'Hide',
          onPressed: onObscureToggle,
        ),
      ),
    );
  }
}
