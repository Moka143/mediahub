import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../models/torrent.dart';
import '../providers/home_recommendations_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/movies_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../screens/movie_details_screen.dart';
import '../screens/show_details_screen.dart';
import 'home/home_cards.dart';
import 'home/home_hero.dart';
import 'home/home_hero_data.dart';
import 'home/home_mini_panel.dart';

/// MediaHub Home — landing page that mirrors `screen-home.jsx`.
///
/// Layout:
///   * Hero card showcasing the most-recent in-progress title (with a
///     Resume CTA when a `WatchProgress` is available, otherwise a
///     poetic empty state for first-run).
///   * Continue Watching row — 16:9 cards with progress bars.
///   * Because you liked X — TMDB per-title recs from favorites.
///   * Freshly Downloaded row — recently-completed torrents.
///   * Two side-by-side panels: Active Downloads (live dl speeds)
///     and "Airing tonight" placeholder.
class MediaHubHomeScreen extends ConsumerWidget {
  const MediaHubHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final continueWatching = ref.watch(continueWatchingProvider);
    final torrents = ref.watch(torrentListProvider).torrents;
    final activeDl = torrents.where((t) => t.isDownloading).toList();
    final freshlyCompleted = torrents
        .where((t) => t.isCompleted || t.isSeeding)
        .toList()
        .reversed
        .take(8)
        .toList();

    // Build a poster lookup table by joining the user's watch
    // progress + local media library — so torrent rows that match a
    // tracked title can render the real TMDB art instead of a flat
    // gradient.
    final progressMap = ref.watch(watchProgressProvider);
    final localFilesAsync = ref.watch(localMediaFilesProvider);
    final localFiles = localFilesAsync.maybeWhen(
      data: (f) => f,
      orElse: () => const <LocalMediaFile>[],
    );
    String? lookupPosterForTorrent(Torrent t) {
      final lower = t.name.toLowerCase();
      // 1) Exact-ish hash match against active streaming entries.
      for (final p in progressMap.values) {
        if (p.posterPath == null || p.posterPath!.isEmpty) continue;
        final showName = p.showName?.toLowerCase();
        if (showName != null &&
            showName.length > 2 &&
            lower.contains(showName)) {
          return p.posterPath;
        }
      }
      // 2) Fall back to the local-media scanner — it tags scanned
      //    files with the resolved show name + poster path.
      for (final f in localFiles) {
        if (f.posterPath == null || f.posterPath!.isEmpty) continue;
        final s = f.showName?.toLowerCase();
        if (s != null && s.length > 2 && lower.contains(s)) {
          return f.posterPath;
        }
      }
      return null;
    }

    // TMDB trending feeds — used to populate the hero + a "Trending"
    // row when the user has no watch progress yet, so the home page
    // always shows real poster art instead of empty gradients.
    final trendingShows = ref.watch(trendingShowsProvider);
    final trendingMovies = ref.watch(trendingMoviesProvider);
    final becauseYouLiked = ref.watch(homeRecommendationsProvider);

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HeroCard(
              continueWatching: continueWatching,
              fallbackShow: trendingShows.maybeWhen(
                data: (s) => s.isEmpty ? null : s.first,
                orElse: () => null,
              ),
              onPrimaryTap: heroPrimaryTap(
                context,
                ref,
                continueWatching,
                localFiles,
              ),
              onSecondaryTap: heroSecondaryTap(
                context,
                ref,
                continueWatching,
                trendingShows,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),

            if (continueWatching.isNotEmpty) ...[
              HomeSectionHeader(
                title: 'Continue Watching',
                // Library tab is index 4 (Home, Transfers, TV Shows,
                // Movies, Library, Calendar, Favorites).
                onSeeAll: () =>
                    ref.read(currentTabIndexProvider.notifier).set(4),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 220,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  itemCount: continueWatching.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpacing.md),
                  itemBuilder: (_, i) {
                    final p = continueWatching[i];
                    // If the WatchProgress entry has no poster path,
                    // try to find one by joining show name against
                    // the local-media library / other progress.
                    String? fallback;
                    if (p.posterPath == null || p.posterPath!.isEmpty) {
                      final name = p.showName?.toLowerCase() ?? '';
                      if (name.isNotEmpty) {
                        for (final f in localFiles) {
                          if (f.posterPath != null &&
                              (f.showName?.toLowerCase() == name)) {
                            fallback = f.posterPath;
                            break;
                          }
                        }
                      }
                    }
                    return ContinueCard(
                      p: p,
                      posterFallback: fallback,
                      onTap: () => resumePlayback(context, ref, p, localFiles),
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],

            becauseYouLiked.maybeWhen(
              data: (feed) => feed == null || feed.items.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HomeSectionHeader(
                          title: 'Because you liked ${feed.becauseTitle}',
                          onSeeAll: () =>
                              ref.read(currentTabIndexProvider.notifier).set(6),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SizedBox(
                          height: 280,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            itemCount: feed.items.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: AppSpacing.md),
                            itemBuilder: (_, i) {
                              final item = feed.items[i];
                              return PosterTile(
                                imageUrl: item.posterUrl,
                                hue: (item.id * 41 % 360).toDouble(),
                                title: item.title,
                                subtitle: item.year,
                                onTap: () {
                                  if (item.show != null) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            ShowDetailsScreen(show: item.show!),
                                      ),
                                    );
                                  } else if (item.movie != null) {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => MovieDetailsScreen(
                                          movie: item.movie!,
                                        ),
                                      ),
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xxl),
                      ],
                    ),
              orElse: () => const SizedBox.shrink(),
            ),

            // Trending Shows row — gives the page real poster art even
            // before the user has any continue-watching history.
            trendingShows.maybeWhen(
              data: (shows) => shows.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HomeSectionHeader(
                          title: 'Trending shows',
                          // Jump to the TV Shows tab.
                          onSeeAll: () =>
                              ref.read(currentTabIndexProvider.notifier).set(2),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SizedBox(
                          height: 280,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            itemCount: shows.length.clamp(0, 14),
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: AppSpacing.md),
                            itemBuilder: (_, i) => PosterTile(
                              imageUrl: shows[i].posterUrl,
                              hue: (shows[i].id * 37 % 360).toDouble(),
                              title: shows[i].name,
                              subtitle: shows[i].year,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ShowDetailsScreen(show: shows[i]),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xxl),
                      ],
                    ),
              orElse: () => const SizedBox.shrink(),
            ),

            // Trending Movies row — same idea for movies.
            trendingMovies.maybeWhen(
              data: (movies) => movies.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        HomeSectionHeader(
                          title: 'Trending movies',
                          // Jump to the Movies tab.
                          onSeeAll: () =>
                              ref.read(currentTabIndexProvider.notifier).set(3),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SizedBox(
                          height: 280,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            itemCount: movies.length.clamp(0, 14),
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: AppSpacing.md),
                            itemBuilder: (_, i) => PosterTile(
                              imageUrl: movies[i].posterUrl,
                              hue: (movies[i].id * 53 % 360).toDouble(),
                              title: movies[i].title,
                              subtitle: movies[i].year,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      MovieDetailsScreen(movie: movies[i]),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xxl),
                      ],
                    ),
              orElse: () => const SizedBox.shrink(),
            ),

            if (freshlyCompleted.isNotEmpty) ...[
              HomeSectionHeader(
                title: 'Freshly downloaded',
                // Jump to the Transfers tab.
                onSeeAll: () =>
                    ref.read(currentTabIndexProvider.notifier).set(1),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 280,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  itemCount: freshlyCompleted.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpacing.md),
                  itemBuilder: (_, i) => FreshTile(
                    t: freshlyCompleted[i],
                    posterPath: lookupPosterForTorrent(freshlyCompleted[i]),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],

            // Bottom panel row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: MiniPanel(
                    title: 'Active downloads',
                    count: activeDl.length,
                    child: activeDl.isEmpty
                        ? const PanelEmpty(label: 'Nothing downloading')
                        : Column(
                            children: [
                              for (final t in activeDl.take(3))
                                MiniTorrentRow(t: t),
                            ],
                          ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: MiniPanel(
                    title: 'Airing tonight',
                    count: 0,
                    child: const PanelEmpty(
                      label: 'Auto-grab is quiet right now',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
