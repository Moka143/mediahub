import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../models/movie.dart';
import '../models/show.dart';
import '../providers/favorites_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/watchlist_provider.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/movie_card.dart';
import '../widgets/show_card.dart';
import 'movie_details_screen.dart';
import 'show_details_screen.dart';

/// Favorites + Watchlist — tabbed.
///
/// Tabs: TV favorites (with upcoming-episodes header), Movie favorites,
/// and a combined watchlist (TV + movies). Everything here mirrors what
/// TMDB has for the signed-in account; toggles in details screens push
/// straight to TMDB.
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.tv_rounded), text: 'TV'),
              Tab(icon: Icon(Icons.movie_rounded), text: 'Movies'),
              Tab(icon: Icon(Icons.bookmark_rounded), text: 'Watchlist'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _TvFavoritesTab(),
                _MovieFavoritesTab(),
                _WatchlistTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// TV favorites (unchanged behavior + upcoming episodes header)
// ============================================================================

class _TvFavoritesTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesState = ref.watch(favoritesProvider);
    final favoriteShows = ref.watch(favoriteShowsProvider);
    final upcomingEpisodes = ref.watch(upcomingEpisodesProvider);
    final appColors = context.appColors;
    final theme = Theme.of(context);

    if (favoritesState.favoriteIds.isEmpty) {
      return _EmptyTab(
        title: 'No TV Favorites Yet',
        subtitle: 'Mark a show as favorite to track new episodes here.',
        icon: Icons.favorite_outline_rounded,
        ctaLabel: 'Discover Shows',
        ctaIcon: Icons.explore_rounded,
        onCta: () => ref.read(currentTabIndexProvider.notifier).set(2),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(favoritesProvider.notifier).syncFromTmdb();
        ref.invalidate(favoriteShowsProvider);
        ref.invalidate(upcomingEpisodesProvider);
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            upcomingEpisodes.when(
              data: (episodes) => episodes.isNotEmpty
                  ? _buildUpcomingSection(context, episodes)
                  : const SizedBox.shrink(),
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                'My Shows (${favoritesState.favoriteIds.length})',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            favoriteShows.when(
              data: (shows) => _ShowsGrid(shows: shows),
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => EmptyState.error(
                message: error.toString(),
                onRetry: () => ref.invalidate(favoriteShowsProvider),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingSection(
    BuildContext context,
    List<UpcomingEpisode> episodes,
  ) {
    final appColors = context.appColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                color: appColors.warning,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.md),
              Text(
                'Upcoming Episodes',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: episodes.length > 5 ? 5 : episodes.length,
          itemBuilder: (context, index) {
            final upcoming = episodes[index];
            return _UpcomingEpisodeItem(
              upcoming: upcoming,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ShowDetailsScreen(show: upcoming.show),
                  ),
                );
              },
            );
          },
        ),
        const Divider(height: AppSpacing.xxl),
      ],
    );
  }
}

// ============================================================================
// Movie favorites
// ============================================================================

class _MovieFavoritesTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(favoritesProvider);
    final movies = ref.watch(favoriteMoviesProvider);

    if (state.favoriteMovieIds.isEmpty) {
      return _EmptyTab(
        title: 'No Movie Favorites Yet',
        subtitle: 'Mark a movie as favorite to find it here later.',
        icon: Icons.favorite_outline_rounded,
        ctaLabel: 'Discover Movies',
        ctaIcon: Icons.explore_rounded,
        onCta: () => ref.read(currentTabIndexProvider.notifier).set(3),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(favoritesProvider.notifier).syncFromTmdb();
        ref.invalidate(favoriteMoviesProvider);
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpacing.md),
            movies.when(
              data: (list) => _MoviesGrid(movies: list),
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => EmptyState.error(
                message: e.toString(),
                onRetry: () => ref.invalidate(favoriteMoviesProvider),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Watchlist (TV + movies combined into two stacked grids)
// ============================================================================

class _WatchlistTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wl = ref.watch(watchlistProvider);
    final shows = ref.watch(watchlistShowsProvider);
    final movies = ref.watch(watchlistMoviesProvider);
    final theme = Theme.of(context);

    if (wl.showIds.isEmpty && wl.movieIds.isEmpty) {
      return _EmptyTab(
        title: 'Watchlist is Empty',
        subtitle: 'Tap the bookmark on any show or movie to save it for later.',
        icon: Icons.bookmark_outline_rounded,
        ctaLabel: 'Browse',
        ctaIcon: Icons.explore_rounded,
        onCta: () => ref.read(currentTabIndexProvider.notifier).set(2),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(watchlistProvider.notifier).syncFromTmdb();
        ref.invalidate(watchlistShowsProvider);
        ref.invalidate(watchlistMoviesProvider);
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (wl.showIds.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text(
                  'TV Shows (${wl.showIds.length})',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              shows.when(
                data: (s) => _ShowsGrid(shows: s),
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) =>
                    EmptyState.error(message: e.toString(), onRetry: null),
              ),
            ],
            if (wl.movieIds.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.xl,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Text(
                  'Movies (${wl.movieIds.length})',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              movies.when(
                data: (m) => _MoviesGrid(movies: m),
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) =>
                    EmptyState.error(message: e.toString(), onRetry: null),
              ),
            ],
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Shared bits
// ============================================================================

class _EmptyTab extends StatelessWidget {
  const _EmptyTab({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.ctaLabel,
    required this.ctaIcon,
    required this.onCta,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String ctaLabel;
  final IconData ctaIcon;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.xl),
              decoration: BoxDecoration(
                color: appColors.errorState.withAlpha(AppOpacity.light),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 64, color: appColors.errorState),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              title,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitle,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: appColors.mutedText),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xxl),
            FilledButton.icon(
              onPressed: onCta,
              icon: Icon(ctaIcon),
              label: Text(ctaLabel),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.md,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShowsGrid extends StatelessWidget {
  const _ShowsGrid({required this.shows});
  final List<Show> shows;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = (width / 200).floor().clamp(2, 6);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.65,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md,
      ),
      itemCount: shows.length,
      itemBuilder: (context, index) {
        final show = shows[index];
        return ShowCard(
          show: show,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ShowDetailsScreen(show: show),
              ),
            );
          },
        );
      },
    );
  }
}

class _MoviesGrid extends StatelessWidget {
  const _MoviesGrid({required this.movies});
  final List<Movie> movies;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = (width / 200).floor().clamp(2, 6);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.65,
        crossAxisSpacing: AppSpacing.md,
        mainAxisSpacing: AppSpacing.md,
      ),
      itemCount: movies.length,
      itemBuilder: (context, index) {
        final movie = movies[index];
        return MovieCard(
          movie: movie,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MovieDetailsScreen(movie: movie),
              ),
            );
          },
        );
      },
    );
  }
}

class _UpcomingEpisodeItem extends StatelessWidget {
  final UpcomingEpisode upcoming;
  final VoidCallback? onTap;

  const _UpcomingEpisodeItem({required this.upcoming, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: SizedBox(
          width: 50,
          height: 75,
          child: upcoming.show.posterUrl != null
              ? Image.network(
                  upcoming.show.posterUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.tv),
                  ),
                )
              : Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.tv),
                ),
        ),
      ),
      title: Text(
        upcoming.show.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _formatAirDate(upcoming.airDate),
        style: TextStyle(color: appColors.mutedText),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: _getTimeColor(upcoming.daysUntilAir, appColors)
              .withAlpha(AppOpacity.light),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          upcoming.daysUntilAirFormatted,
          style: TextStyle(
            color: _getTimeColor(upcoming.daysUntilAir, appColors),
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  String _formatAirDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('EEEE, MMM d').format(date);
    } catch (_) {
      return dateStr;
    }
  }

  Color _getTimeColor(int days, AppColorsExtension appColors) {
    if (days <= 0) return appColors.success;
    if (days <= 1) return appColors.warning;
    if (days <= 7) return appColors.queued;
    return appColors.paused;
  }
}
