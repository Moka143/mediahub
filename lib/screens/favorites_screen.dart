import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/episode.dart';
import '../models/movie.dart';
import '../models/show.dart';
import '../models/upcoming_episode.dart';
import '../providers/auto_download_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/tmdb_synced_ids.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/watchlist_provider.dart';
import '../utils/error_messages.dart';
import '../utils/feedback_utils.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/hub_pressable.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/details/show_auto_download_controls.dart';
import '../widgets/editorial/editorial.dart';
import '../widgets/media/hue_backdrop.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/media/row_header.dart';
import 'movie_details_screen.dart';
import 'show_details_screen.dart';

/// Favorites + Watchlist — tabbed: favourite shows (with their upcoming
/// episodes), favourite movies, and the watchlist.
///
/// Everything here mirrors the TMDB account when signed in; Refresh pulls
/// it again. Pull-to-refresh was the only way to do that before, and it is
/// not a gesture anyone tries on a desktop.
class FavoritesScreen extends ConsumerStatefulWidget {
  const FavoritesScreen({super.key});

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  bool _refreshing = false;

  /// Sync both lists with TMDB, then reload every title's details.
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final favorites = ref.read(favoritesProvider.notifier);
    final watchlist = ref.read(watchlistProvider.notifier);

    String? failure;
    var signedOut = false;
    try {
      final results = <TmdbSyncResult>[
        await favorites.syncFromTmdb(),
        await watchlist.syncFromTmdb(),
      ];
      signedOut = results.every((r) => r.outcome == TmdbSyncOutcome.signedOut);
      for (final r in results) {
        if (!r.ok) failure ??= r.message;
      }
    } catch (e) {
      failure = friendlyErrorMessage(e, subject: 'your TMDB lists');
    }
    if (!mounted) return;

    ref
      ..invalidate(favoriteShowsProvider)
      ..invalidate(favoriteMoviesProvider)
      ..invalidate(watchlistShowsProvider)
      ..invalidate(watchlistMoviesProvider);
    setState(() => _refreshing = false);

    if (failure != null) {
      AppSnackBar.showError(context, message: failure);
    } else {
      AppSnackBar.showInfo(
        context,
        message: signedOut ? 'Favorites reloaded' : 'Synced with TMDB',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.tv_rounded), text: 'Shows'),
                    Tab(icon: Icon(Icons.movie_rounded), text: 'Movies'),
                    Tab(icon: Icon(Icons.bookmark_rounded), text: 'Watchlist'),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: _refreshing
                    ? const SizedBox(
                        width: 32,
                        height: 32,
                        child: Padding(
                          padding: EdgeInsets.all(AppSpacing.sm),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Tooltip(
                        message: 'Sync favorites and watchlist with TMDB',
                        child: EditorialButton(
                          label: 'Refresh',
                          icon: Icons.refresh_rounded,
                          kind: EditorialButtonKind.ghost,
                          onPressed: () => unawaited(_refresh()),
                        ),
                      ),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ShowsTab(onRefresh: _refresh),
                _MoviesTab(onRefresh: _refresh),
                _WatchlistTab(onRefresh: _refresh),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

void _openShow(BuildContext context, Show show) => unawaited(
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => ShowDetailsScreen(show: show))),
);

void _openMovie(BuildContext context, Movie movie) => unawaited(
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => MovieDetailsScreen(movie: movie))),
);

// ============================================================================
// Favourite shows
// ============================================================================

class _ShowsTab extends ConsumerWidget {
  const _ShowsTab({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(favoritesProvider.select((s) => s.favoriteIds));
    if (ids.isEmpty) {
      return _EmptyTab(
        icon: Icons.favorite_outline_rounded,
        title: 'No favorite shows yet',
        subtitle:
            'Favorite a show to follow it here — its new episodes appear '
            'in Calendar.',
        ctaLabel: 'Browse shows',
        onCta: () =>
            ref.read(currentTabIndexProvider.notifier).show(AppTab.shows),
      );
    }

    final showsAsync = ref.watch(favoriteShowsProvider);
    final upcoming =
        ref.watch(upcomingEpisodesProvider).value ?? const <UpcomingEpisode>[];

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: _ListState<Show>(
        async: showsAsync,
        expected: ids.length,
        subject: 'your favorite shows',
        onRetry: () => ref.invalidate(favoriteShowsProvider),
        builder: (shows) => [
          if (upcoming.isNotEmpty) ...[
            const _TabHeader(title: 'Upcoming episodes'),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              sliver: SliverList.list(
                children: [
                  for (final u in upcoming.take(5))
                    _UpcomingEpisodeRow(
                      upcoming: u,
                      onTap: () => _openShow(context, u.show),
                    ),
                ],
              ),
            ),
          ],
          _TabHeader(title: 'My shows', note: '${shows.length}'),
          _PosterGrid<Show>(
            items: shows,
            cardBuilder: (context, show) => _FavoriteShowCard(show: show),
          ),
        ],
      ),
    );
  }
}

/// A favourite show's card, saying where its automatic downloads stand —
/// the "status indicators on the Favorites screen" the README promised.
class _FavoriteShowCard extends ConsumerWidget {
  const _FavoriteShowCard({required this.show});

  final Show show;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracking = ref.watch(showAutoDownloadTrackingProvider(show.id));
    final override = ref.watch(
      autoDownloadProvider.select((s) => s.showAutoDownloadOverrides[show.id]),
    );
    final status = tracking != null
        ? autoDownloadStatusLabel(tracking)
        : switch (override) {
            true => 'Auto-download on',
            false => 'Auto-download off',
            null => null,
          };
    return MediaPosterCard.show(
      show,
      subtitle: status,
      onTap: () => _openShow(context, show),
    );
  }
}

// ============================================================================
// Favourite movies
// ============================================================================

class _MoviesTab extends ConsumerWidget {
  const _MoviesTab({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(favoritesProvider.select((s) => s.favoriteMovieIds));
    if (ids.isEmpty) {
      return _EmptyTab(
        icon: Icons.favorite_outline_rounded,
        title: 'No favorite movies yet',
        subtitle: 'Favorite a movie to find it here later.',
        ctaLabel: 'Browse movies',
        onCta: () =>
            ref.read(currentTabIndexProvider.notifier).show(AppTab.movies),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: _ListState<Movie>(
        async: ref.watch(favoriteMoviesProvider),
        expected: ids.length,
        subject: 'your favorite movies',
        onRetry: () => ref.invalidate(favoriteMoviesProvider),
        builder: (movies) => [
          _TabHeader(title: 'My movies', note: '${movies.length}'),
          _PosterGrid<Movie>(items: movies, cardBuilder: _movieCard),
        ],
      ),
    );
  }
}

Widget _movieCard(BuildContext context, Movie movie) => Consumer(
  builder: (context, ref, _) => MediaPosterCard.movie(
    movie,
    isWatched: ref.watch(isMovieWatchedProvider(movie.id)),
    onTap: () => _openMovie(context, movie),
  ),
);

// ============================================================================
// Watchlist (shows and movies)
// ============================================================================

class _WatchlistTab extends ConsumerWidget {
  const _WatchlistTab({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showIds = ref.watch(watchlistProvider.select((s) => s.showIds));
    final movieIds = ref.watch(watchlistProvider.select((s) => s.movieIds));
    if (showIds.isEmpty && movieIds.isEmpty) {
      return _EmptyTab(
        icon: Icons.bookmark_outline_rounded,
        title: 'Your watchlist is empty',
        subtitle:
            'Click the bookmark on any show or movie to save it for later.',
        ctaLabel: 'Browse shows',
        onCta: () =>
            ref.read(currentTabIndexProvider.notifier).show(AppTab.shows),
      );
    }

    final shows = ref.watch(watchlistShowsProvider);
    final movies = ref.watch(watchlistMoviesProvider);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (showIds.isNotEmpty)
            ..._section<Show>(
              title: 'Shows',
              async: shows,
              expected: showIds.length,
              subject: 'your watchlist shows',
              onRetry: () => ref.invalidate(watchlistShowsProvider),
              cardBuilder: (context, show) => MediaPosterCard.show(
                show,
                onTap: () => _openShow(context, show),
              ),
            ),
          if (movieIds.isNotEmpty)
            ..._section<Movie>(
              title: 'Movies',
              async: movies,
              expected: movieIds.length,
              subject: 'your watchlist movies',
              onRetry: () => ref.invalidate(watchlistMoviesProvider),
              cardBuilder: _movieCard,
            ),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
        ],
      ),
    );
  }

  /// One watchlist section: header and grid, or a compact inline loading or
  /// error state — never a second full-page spinner.
  List<Widget> _section<T>({
    required String title,
    required AsyncValue<List<T>> async,
    required int expected,
    required String subject,
    required VoidCallback onRetry,
    required Widget Function(BuildContext, T) cardBuilder,
  }) {
    final items = async.value;
    final count = items?.length ?? expected;
    return [
      _TabHeader(title: title, note: '$count'),
      if (items != null && items.isNotEmpty)
        _PosterGrid<T>(items: items, cardBuilder: cardBuilder)
      else if (async.hasError || (items != null && items.isEmpty))
        SliverToBoxAdapter(
          child: _InlineError(
            message: async.hasError
                ? friendlyErrorMessage(async.error!, subject: subject)
                : "Couldn't load $subject. Try again.",
            onRetry: onRetry,
          ),
        )
      else
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: LoadingIndicator(),
          ),
        ),
    ];
  }
}

// ============================================================================
// Shared bits
// ============================================================================

/// A tab's body for one list of titles: one loading state for the whole tab
/// (the shows tab used to stack two spinners with a header between them),
/// "couldn't load" kept apart from "empty", and a note when only some of
/// the titles loaded.
class _ListState<T> extends StatelessWidget {
  const _ListState({
    required this.async,
    required this.expected,
    required this.subject,
    required this.onRetry,
    required this.builder,
  });

  final AsyncValue<List<T>> async;

  /// How many titles the list holds — what a complete load returns.
  final int expected;
  final String subject;
  final VoidCallback onRetry;
  final List<Widget> Function(List<T> items) builder;

  @override
  Widget build(BuildContext context) {
    final items = async.value;
    final List<Widget> slivers;
    if (items != null && items.isNotEmpty) {
      slivers = [
        if (items.length < expected)
          SliverToBoxAdapter(
            child: _InlineError(
              message:
                  "Couldn't load ${expected - items.length} of $expected — "
                  'they may be missing below.',
              onRetry: onRetry,
            ),
          ),
        ...builder(items),
      ];
    } else if (async.hasError || items != null) {
      // Titles were expected and none came back — a failed load, not an
      // empty list.
      slivers = [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState.error(
            title: "Couldn't load $subject",
            message: async.hasError
                ? friendlyErrorMessage(async.error!, subject: subject)
                : "TMDB didn't return any of them. Try again in a moment.",
            onRetry: onRetry,
          ),
        ),
      ];
    } else {
      slivers = const [
        SliverFillRemaining(hasScrollBody: false, child: LoadingIndicator()),
      ];
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        ...slivers,
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
      ],
    );
  }
}

/// The one poster grid for every list on this screen — shows and movies
/// each had their own identical copy.
class _PosterGrid<T> extends StatelessWidget {
  const _PosterGrid({required this.items, required this.cardBuilder});

  final List<T> items;
  final Widget Function(BuildContext context, T item) cardBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          childAspectRatio: 2 / 3,
          crossAxisSpacing: AppSpacing.md,
          mainAxisSpacing: AppSpacing.md,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => cardBuilder(context, items[i]),
          childCount: items.length,
        ),
      ),
    );
  }
}

class _TabHeader extends StatelessWidget {
  const _TabHeader({required this.title, this.note});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      sliver: SliverToBoxAdapter(
        child: RowHeader(title: title, note: note, size: AppType.sizeTitle),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.warn,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(message, style: AppType.caption(color: AppColors.fg1)),
          ),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.ctaLabel,
    required this.onCta,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String ctaLabel;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) {
    // Neutral, not the red error treatment this used to borrow: an empty
    // list is not a failure.
    return EmptyState(
      icon: icon,
      title: title,
      subtitle: subtitle,
      action: EditorialButton(
        label: ctaLabel,
        icon: Icons.explore_rounded,
        kind: EditorialButtonKind.accent,
        onPressed: onCta,
      ),
    );
  }
}

class _UpcomingEpisodeRow extends StatelessWidget {
  const _UpcomingEpisodeRow({required this.upcoming, required this.onTap});

  final UpcomingEpisode upcoming;
  final VoidCallback onTap;

  Color _tone(int days) {
    if (days <= 0) return AppColors.ok;
    if (days <= 1) return AppColors.warn;
    if (days <= 7) return AppColors.accent;
    return AppColors.fg2;
  }

  @override
  Widget build(BuildContext context) {
    final show = upcoming.show;
    final days = upcoming.daysUntilAir;
    final tone = _tone(days);
    final date = parseAirDate(upcoming.airDate);
    final next = show.nextEpisode;
    return HubPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.xs),
              child: SizedBox(
                width: 40,
                height: 60,
                child: show.posterUrl != null
                    ? CachedNetworkImage(
                        imageUrl: show.posterUrl!,
                        fit: BoxFit.cover,
                        memCacheWidth: 120,
                        errorWidget: (_, _, _) =>
                            HueBackdrop(hue: hueForId(show.id)),
                        placeholder: (_, _) =>
                            HueBackdrop(hue: hueForId(show.id)),
                      )
                    : HueBackdrop(hue: hueForId(show.id)),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    show.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      size: AppType.sizeLead,
                      color: AppColors.fg,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (next != null) next.episodeCode,
                      if (date != null) DateFormat('EEEE, MMM d').format(date),
                    ].join(' · '),
                    style: AppType.caption(),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              decoration: BoxDecoration(
                color: tone.withAlpha(AppOpacity.light),
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: Text(
                upcoming.daysUntilAirFormatted,
                style: AppType.ui(
                  size: AppType.sizeCaption,
                  color: tone,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
