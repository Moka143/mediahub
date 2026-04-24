import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../models/show.dart';
import '../providers/favorites_provider.dart';
import '../providers/navigation_provider.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/show_card.dart';
import 'show_details_screen.dart';

/// Screen for displaying favorite shows and upcoming episodes
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesState = ref.watch(favoritesProvider);
    final favoriteShows = ref.watch(favoriteShowsProvider);
    final upcomingEpisodes = ref.watch(upcomingEpisodesProvider);
    final appColors = context.appColors;
    final theme = Theme.of(context);

    if (favoritesState.favoriteIds.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Heart icon with gradient background
              Container(
                padding: const EdgeInsets.all(AppSpacing.xl),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      appColors.errorState.withAlpha(AppOpacity.light),
                      appColors.errorState.withAlpha(AppOpacity.subtle),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.favorite_outline_rounded,
                  size: 64,
                  color: appColors.errorState,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'No Favorites Yet',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Keep track of shows you love!\nAdd favorites to see upcoming episodes.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: appColors.mutedText,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xxl),
              FilledButton.icon(
                onPressed: () {
                  ref.read(currentTabIndexProvider.notifier).set(1);
                },
                icon: const Icon(Icons.explore_rounded),
                label: const Text('Discover Shows'),
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

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(favoriteShowsProvider);
        ref.invalidate(upcomingEpisodesProvider);
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Upcoming episodes section
            upcomingEpisodes.when(
              data: (episodes) => episodes.isNotEmpty
                  ? _buildUpcomingSection(context, episodes, ref)
                  : const SizedBox.shrink(),
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),

            // Favorite shows section
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: appColors.errorState.withAlpha(AppOpacity.light),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(Icons.favorite_rounded, color: appColors.errorState, size: 20),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Text(
                    'My Shows (${favoritesState.favoriteIds.length})',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ],
              ),
            ),

            favoriteShows.when(
              data: (shows) => _buildShowsGrid(context, shows, ref),
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
    WidgetRef ref,
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
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: appColors.warning.withAlpha(AppOpacity.light),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.schedule_rounded, color: appColors.warning, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Text(
                'Upcoming Episodes',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
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
                    builder: (context) => ShowDetailsScreen(show: upcoming.show),
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

  Widget _buildShowsGrid(BuildContext context, List<Show> shows, WidgetRef ref) {
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
                builder: (context) => ShowDetailsScreen(show: show),
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

  const _UpcomingEpisodeItem({
    required this.upcoming,
    this.onTap,
  });

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
          color: _getTimeColor(upcoming.daysUntilAir, appColors).withAlpha(AppOpacity.light),
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
