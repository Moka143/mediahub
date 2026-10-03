import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/movie.dart';
import '../models/show.dart';
import '../models/torrent.dart';
import '../providers/calendar_provider.dart';
import '../providers/home_recommendations_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/movies_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../utils/error_messages.dart';
import '../widgets/library/library.dart';
import '../widgets/media/continue_watching_card.dart';
import '../widgets/media/local_playback.dart';
import '../widgets/media/media_poster_card.dart';
import 'home/home_cards.dart';
import 'home/home_hero.dart';
import 'home/home_hero_data.dart';
import 'home/home_mini_panel.dart';
import 'movie_details_screen.dart';
import 'settings_screen.dart';
import 'show_details_screen.dart';

/// MediaHub Home.
///
///   * Hero — the title in progress (Resume), or the week's top trending
///     show before anything has been watched.
///   * Continue watching, Because you liked, Trending shows and movies.
///   * Freshly downloaded — finished downloads, newest first.
///   * Active downloads and today's episodes from favourite shows.
///
/// Nothing here watches the torrent list: the two parts that show torrents
/// watch it themselves, so the two-second poll rebuilds them rather than
/// the whole page.
class MediaHubHomeScreen extends ConsumerWidget {
  const MediaHubHomeScreen({super.key});

  void _push(BuildContext context, Widget page) => unawaited(
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
  );

  void _showTab(WidgetRef ref, AppTab tab) =>
      ref.read(currentTabIndexProvider.notifier).show(tab);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final continueWatching = ref.watch(continueWatchingProvider);
    final trendingShowsAsync = ref.watch(trendingShowsProvider);
    final trendingShows = trendingShowsAsync.value ?? const <Show>[];
    final trendingMovies = ref.watch(trendingMoviesProvider).value ?? const [];
    final recs = ref.watch(homeRecommendationsProvider).value;
    final hero = continueWatching.firstOrNull;
    final fallbackShow = trendingShows.firstOrNull;
    final actions = LibraryActions.standard(context, ref);

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HeroCard(
              progress: hero,
              art: hero == null
                  ? null
                  : ref.watch(homeContinueHeroArtProvider).value,
              fallbackShow: fallbackShow,
              onPrimaryTap: () {
                if (hero != null) {
                  actions.playProgress(hero);
                } else if (fallbackShow != null) {
                  _push(
                    context,
                    ShowDetailsScreen(
                      show: fallbackShow,
                      autoOpenEpisodesDrawer: true,
                    ),
                  );
                } else {
                  _showTab(ref, AppTab.shows);
                }
              },
              onSecondaryTap: hero != null
                  ? () => unawaited(openProgressDetails(context, ref, hero))
                  : fallbackShow != null
                  ? () => _push(context, ShowDetailsScreen(show: fallbackShow))
                  : null,
            ),
            const SizedBox(height: AppSpacing.xxl),

            // TMDB unreachable, or the token rejected: say so, rather than
            // letting the rows below quietly not appear.
            if (trendingShowsAsync.hasError && trendingShows.isEmpty)
              _FeedProblem(error: trendingShowsAsync.error!),

            if (continueWatching.isNotEmpty)
              HomeRow(
                title: 'Continue watching',
                onSeeAll: () => _showTab(ref, AppTab.library),
                // These cards carry a caption; the height is measured
                // through the text scaler so large text doesn't clip it.
                height: MediaPosterCard.heightForWidth(context),
                itemCount: continueWatching.length,
                itemBuilder: (_, i) {
                  final p = continueWatching[i];
                  return ContinueWatchingCard(
                    progress: p,
                    onTap: () => actions.playProgress(p),
                    onRemove: () => actions.removeProgress(p),
                    onMarkWatched: () =>
                        actions.markWatched(actions.fileFor(ref, p)),
                    onDelete: () => actions.deleteFile(actions.fileFor(ref, p)),
                  );
                },
              ),

            if (recs != null && recs.items.isNotEmpty)
              HomeRow(
                title: 'Because you liked ${recs.becauseTitle}',
                onSeeAll: () => _showTab(ref, AppTab.favorites),
                itemCount: recs.items.length,
                itemBuilder: (context, i) {
                  final item = recs.items[i];
                  final show = item.show;
                  final movie = item.movie;
                  return show != null
                      ? _showCard(context, show)
                      : _movieCard(context, movie!);
                },
              ),

            if (trendingShows.isNotEmpty)
              HomeRow(
                title: 'Trending shows',
                onSeeAll: () => _showTab(ref, AppTab.shows),
                itemCount: trendingShows.length.clamp(0, 14),
                itemBuilder: (context, i) =>
                    _showCard(context, trendingShows[i]),
              ),

            if (trendingMovies.isNotEmpty)
              HomeRow(
                title: 'Trending movies',
                onSeeAll: () => _showTab(ref, AppTab.movies),
                itemCount: trendingMovies.length.clamp(0, 14),
                itemBuilder: (context, i) =>
                    _movieCard(context, trendingMovies[i]),
              ),

            const _FreshlyDownloadedRow(),

            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _ActiveDownloadsPanel()),
                SizedBox(width: AppSpacing.lg),
                Expanded(child: _AiringTodayPanel()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _showCard(BuildContext context, Show show) => MediaPosterCard.show(
    show,
    width: homeCardWidth,
    onTap: () => _push(context, ShowDetailsScreen(show: show)),
  );

  Widget _movieCard(BuildContext context, Movie movie) => Consumer(
    builder: (context, ref, _) => MediaPosterCard.movie(
      movie,
      width: homeCardWidth,
      isWatched: ref.watch(isMovieWatchedProvider(movie.id)),
      onTap: () => _push(context, MovieDetailsScreen(movie: movie)),
    ),
  );
}

/// A line under the hero when TMDB's feeds could not be loaded.
class _FeedProblem extends ConsumerWidget {
  const _FeedProblem({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsSettings = failureNeedsSettings(error);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.warn.withAlpha(AppOpacity.subtle),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.33)),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 16,
              color: AppColors.warn,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                friendlyErrorMessage(error, subject: "what's trending"),
                style: AppType.caption(color: AppColors.fg1),
              ),
            ),
            if (needsSettings)
              TextButton(
                onPressed: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
                child: const Text('Open Settings'),
              )
            else
              TextButton(
                onPressed: () => ref
                  ..invalidate(trendingShowsProvider)
                  ..invalidate(trendingMoviesProvider),
                child: const Text('Try again'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Open a torrent in Transfers, selected.
void _openInTransfers(WidgetRef ref, Torrent torrent) {
  ref.read(selectedTorrentHashProvider.notifier).set(torrent.hash);
  ref.read(currentTabIndexProvider.notifier).show(AppTab.transfers);
}

class _FreshlyDownloadedRow extends ConsumerWidget {
  const _FreshlyDownloadedRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuilds when which torrents are fresh changes — not on every poll.
    final key = ref.watch(
      torrentListProvider.select(
        (s) => freshlyDownloaded(s.torrents).map((t) => t.hash).join(','),
      ),
    );
    if (key.isEmpty) return const SizedBox.shrink();
    final fresh = freshlyDownloaded(ref.read(torrentListProvider).torrents);

    return HomeRow(
      title: 'Freshly downloaded',
      onSeeAll: () =>
          ref.read(currentTabIndexProvider.notifier).show(AppTab.transfers),
      itemCount: fresh.length,
      itemBuilder: (context, i) {
        final torrent = fresh[i];
        return FreshTile(
          torrent: torrent,
          onTap: () {
            final files = ref.read(localMediaFilesProvider).value ?? const [];
            final file = libraryFileForTorrent(torrent, files);
            if (file != null) {
              unawaited(openLocalFile(context, ref, file));
            } else {
              // Not a single playable file — a pack, or not scanned yet.
              _openInTransfers(ref, torrent);
            }
          },
        );
      },
    );
  }
}

class _ActiveDownloadsPanel extends ConsumerWidget {
  const _ActiveDownloadsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      torrentListProvider.select(
        (s) => _ActiveSnapshot([
          for (final t in s.torrents)
            if (t.isDownloading) t,
        ]),
      ),
    );
    final torrents = active.torrents;
    return MiniPanel(
      title: 'Active downloads',
      countLabel: torrents.isEmpty ? null : '${torrents.length} active',
      onTitleTap: () =>
          ref.read(currentTabIndexProvider.notifier).show(AppTab.transfers),
      child: torrents.isEmpty
          ? const PanelEmpty(label: 'Nothing downloading')
          : Column(
              children: [
                for (final t in torrents.take(3))
                  MiniTorrentRow(t: t, onTap: () => _openInTransfers(ref, t)),
              ],
            ),
    );
  }
}

/// What the active-downloads panel shows, compared by what it draws — so the
/// panel rebuilds when a figure on it changes, and not on every poll.
@immutable
class _ActiveSnapshot {
  const _ActiveSnapshot(this.torrents);

  final List<Torrent> torrents;

  static const _equality =
      ListEquality<
        ({String hash, String name, double progress, int dlspeed})
      >();

  List<({String hash, String name, double progress, int dlspeed})> get _shown =>
      [
        for (final t in torrents)
          (
            hash: t.hash,
            name: t.name,
            progress: t.progress,
            dlspeed: t.dlspeed,
          ),
      ];

  @override
  bool operator ==(Object other) =>
      other is _ActiveSnapshot && _equality.equals(other._shown, _shown);

  @override
  int get hashCode => _equality.hash(_shown);
}

/// Today's episodes from favourite shows, from the calendar's data. It was
/// hard-coded to zero with "Auto-grab is quiet right now".
class _AiringTodayPanel extends ConsumerWidget {
  const _AiringTodayPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(calendarEpisodesProvider);
    final data = async.value;
    final today = data?.on(DateTime.now()) ?? const <CalendarEpisode>[];
    void openCalendar() =>
        ref.read(currentTabIndexProvider.notifier).show(AppTab.calendar);

    final Widget body;
    if (data == null) {
      body = PanelEmpty(
        label: async.hasError
            ? "Couldn't check today's episodes."
            : 'Checking your shows…',
      );
    } else if (data.showCount == 0) {
      body = const PanelEmpty(label: 'Favorite a show to see when it airs.');
    } else if (data.allFailed) {
      body = const PanelEmpty(label: "Couldn't check today's episodes.");
    } else if (today.isEmpty) {
      body = const PanelEmpty(label: 'Nothing from your favorites airs today.');
    } else {
      body = Column(
        children: [
          for (final e in today.take(3))
            MiniAiringRow(
              showName: e.showName,
              episodeCode: e.episodeCode,
              onTap: openCalendar,
            ),
        ],
      );
    }

    return MiniPanel(
      // TMDB dates carry no time of day — "today" is as exact as it gets.
      title: 'Airing today',
      countLabel: today.isEmpty ? null : '${today.length} today',
      onTitleTap: openCalendar,
      child: body,
    );
  }
}
