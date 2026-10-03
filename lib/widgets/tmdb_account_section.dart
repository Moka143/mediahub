import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../providers/favorites_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/watchlist_provider.dart';
import '../services/library_actions.dart';
import '../utils/error_messages.dart';

/// Two-step TMDB sign-in, and the signed-in account's sync controls:
///   1. "Sign in with TMDB" opens the browser to approve a request token.
///   2. "Finish sign-in" exchanges it for a session and syncs the lists.
class TmdbAccountSection extends ConsumerStatefulWidget {
  const TmdbAccountSection({super.key});

  @override
  ConsumerState<TmdbAccountSection> createState() => _TmdbAccountSectionState();
}

class _TmdbAccountSectionState extends ConsumerState<TmdbAccountSection> {
  String? _pendingToken;
  bool _busy = false;
  String? _error;

  /// When this section last synced successfully. "(synced)" used to be
  /// printed unconditionally, so a refresh that failed offline still looked
  /// like it had worked.
  DateTime? _syncedAt;

  /// Changes made here that TMDB has not confirmed yet, as of the last sync.
  int _pendingChanges = 0;

  Future<void> _start() async {
    final session = ref.read(tmdbSessionProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = await session.beginSignIn();
      if (mounted) setState(() => _pendingToken = token);
    } catch (e) {
      if (mounted) {
        setState(() => _error = friendlyErrorMessage(e, subject: 'TMDB'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final token = _pendingToken;
    if (token == null) return;
    final session = ref.read(tmdbSessionProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.completeSignIn(token);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          // An unapproved or expired request is the usual cause, and TMDB
          // answers it the same way it answers a bad token — so say what to
          // do about the likely case rather than blame the token.
          final kind = classifyFailure(e);
          _error = kind == FailureKind.offline || kind == FailureKind.timeout
              ? friendlyErrorMessage(e)
              : 'TMDB didn\'t confirm the sign-in. Approve MediaHub in the '
                    'browser page, then click Finish sign-in — or start over '
                    'if that page has expired.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _pendingToken = null);
    // Push any pre-existing local entries up first, then pull TMDB truth.
    await _sync(pushLocalFirst: true);
  }

  Future<void> _signOut() async {
    final session = ref.read(tmdbSessionProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.signOut();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _syncedAt = null;
          _pendingChanges = 0;
        });
      }
    }
  }

  /// Sync favorites, watchlist and watched marks with TMDB, and report the
  /// outcome here. Each part is attempted even when another fails.
  Future<void> _sync({bool pushLocalFirst = false}) async {
    final favorites = ref.read(favoritesProvider.notifier);
    final watchlist = ref.read(watchlistProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });

    // The syncs report rather than throw; anything that does throw is still
    // a failure to report, not one to lose.
    String? failure;
    var pending = 0;
    try {
      final results = [
        await favorites.syncFromTmdb(pushLocalFirst: pushLocalFirst),
        await watchlist.syncFromTmdb(pushLocalFirst: pushLocalFirst),
        // Push-first on sign-in so locally watched items marked before
        // signing in propagate up; later syncs pull TMDB as the truth so an
        // unmark on another device flows back. It needs a live WidgetRef.
        if (mounted)
          await reconcileWatchedWithTmdb(ref, pushLocalFirst: pushLocalFirst),
      ];
      for (final result in results) {
        pending += result.pendingChanges;
        if (!result.ok) failure ??= result.message ?? '';
      }
    } catch (e) {
      failure ??= friendlyErrorMessage(e, subject: 'your TMDB lists');
    }

    if (!mounted) return;
    final reason = failure;
    setState(() {
      _busy = false;
      _pendingChanges = pending;
      if (reason == null) {
        _syncedAt = DateTime.now();
      } else {
        _error =
            'Couldn\'t sync with TMDB. ${reason.isEmpty ? '' : '$reason '}'
            'Your lists are kept on this computer and sync next time.';
      }
    });
  }

  void _cancelPending() => setState(() {
    _pendingToken = null;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(tmdbSessionProvider);
    final hasKey = ref.watch(hasTmdbApiKeyProvider);

    if (!hasKey) {
      return Text(
        'Add a TMDB token above, then sign in here.',
        style: AppType.body(),
      );
    }

    final error = _error == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: AppType.caption(color: AppColors.err),
              ),
            ),
          );

    if (session != null) {
      final favorites = ref.watch(favoritesProvider);
      final watchlist = ref.watch(watchlistProvider);
      final favCount =
          favorites.favoriteIds.length + favorites.favoriteMovieIds.length;
      final wlCount = watchlist.showIds.length + watchlist.movieIds.length;
      final syncing = _busy || favorites.isSyncing || watchlist.isSyncing;
      final syncedAt = _syncedAt;
      // A failure of the launch-time sync, which ran without this section;
      // one from a sync started here is in [_error] already.
      final lastSyncError = _error == null && syncedAt == null
          ? favorites.error ?? watchlist.error
          : null;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: AppColors.ok),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Signed in as ${session.account.username}',
                  style: AppType.bodyStrong(),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            [
              '$favCount ${favCount == 1 ? 'favorite' : 'favorites'}',
              '$wlCount on your watchlist',
              if (syncing)
                'syncing…'
              else if (syncedAt != null)
                'synced at ${TimeOfDay.fromDateTime(syncedAt).format(context)}',
              if (!syncing && _pendingChanges > 0)
                _pendingChanges == 1
                    ? '1 change waiting to reach TMDB'
                    : '$_pendingChanges changes waiting to reach TMDB',
            ].join(' · '),
            style: AppType.caption(),
          ),
          if (!syncing && lastSyncError != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Last sync didn\'t finish: $lastSyncError',
                style: AppType.caption(color: AppColors.warn),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              OutlinedButton.icon(
                onPressed: syncing ? null : () => unawaited(_sync()),
                icon: syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(syncing ? 'Syncing…' : 'Sync now'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => unawaited(_signOut()),
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('Sign out'),
              ),
            ],
          ),
          ?error,
        ],
      );
    }

    if (_pendingToken != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'A TMDB page opened in your browser. Approve MediaHub there, '
            'then come back and click Finish sign-in.',
            style: AppType.body(),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => unawaited(_finish()),
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('Finish sign-in'),
              ),
              // The approval page expires, and a denied request fails the
              // same way every time: without a way to ask again, the only
              // escape used to be leaving Settings.
              OutlinedButton.icon(
                onPressed: _busy ? null : () => unawaited(_start()),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Start over'),
              ),
              TextButton(
                onPressed: _busy ? null : _cancelPending,
                child: const Text('Cancel'),
              ),
            ],
          ),
          ?error,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in to keep your favorites and watchlist in sync with TMDB '
          'across devices.',
          style: AppType.body(),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : () => unawaited(_start()),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: const Text('Sign in with TMDB'),
          ),
        ),
        ?error,
      ],
    );
  }
}
