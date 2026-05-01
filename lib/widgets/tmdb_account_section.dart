import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/favorites_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/watchlist_provider.dart';

/// Two-step TMDB sign-in:
///   1. Press "Connect" → opens browser with the request token to approve
///   2. Press "I've approved it" → exchanges for a session and pulls lists
class TmdbAccountSection extends ConsumerStatefulWidget {
  const TmdbAccountSection({super.key});

  @override
  ConsumerState<TmdbAccountSection> createState() =>
      _TmdbAccountSectionState();
}

class _TmdbAccountSectionState extends ConsumerState<TmdbAccountSection> {
  String? _pendingToken;
  bool _busy = false;
  String? _error;

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await ref
          .read(tmdbSessionProvider.notifier)
          .beginSignIn();
      if (mounted) setState(() => _pendingToken = token);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final token = _pendingToken;
    if (token == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(tmdbSessionProvider.notifier).completeSignIn(token);
      // Push any pre-existing local entries up first, then pull TMDB truth.
      await ref
          .read(favoritesProvider.notifier)
          .syncFromTmdb(pushLocalFirst: true);
      await ref
          .read(watchlistProvider.notifier)
          .syncFromTmdb(pushLocalFirst: true);
      if (mounted) setState(() => _pendingToken = null);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await ref.read(tmdbSessionProvider.notifier).signOut();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      await ref.read(favoritesProvider.notifier).syncFromTmdb();
      await ref.read(watchlistProvider.notifier).syncFromTmdb();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(tmdbSessionProvider);
    final hasKey = ref.watch(hasTmdbApiKeyProvider);
    final theme = Theme.of(context);

    if (!hasKey) {
      return Text(
        'Add your TMDB API key above before connecting your account.',
        style: theme.textTheme.bodyMedium,
      );
    }

    if (session != null) {
      final favCount =
          ref.watch(favoritesProvider).favoriteIds.length +
          ref.watch(favoritesProvider).favoriteMovieIds.length;
      final wlCount =
          ref.watch(watchlistProvider).showIds.length +
          ref.watch(watchlistProvider).movieIds.length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Connected as ${session.account.username}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$favCount favorites, $wlCount on watchlist (synced)',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text('Refresh from TMDB'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _signOut,
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Sign out'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      );
    }

    if (_pendingToken != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A TMDB authorization page should have opened in your browser. '
            'Approve access there, then come back and tap the button below.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _finish,
            icon: const Icon(Icons.check_rounded),
            label: const Text("I've approved it — finish sign-in"),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in to keep your favorites and watchlist in sync with TMDB '
          'across devices.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _start,
          icon: const Icon(Icons.login_rounded),
          label: const Text('Connect TMDB account'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}
