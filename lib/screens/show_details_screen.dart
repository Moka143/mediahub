import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../models/season.dart';
import '../models/show.dart';
import '../models/torrentio_stream.dart';
import '../providers/auto_download_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/torrentio_provider.dart';
import '../providers/watchlist_provider.dart';
import '../services/library_actions.dart';
import '../utils/error_messages.dart';
import '../utils/feedback_utils.dart';
import '../widgets/details/detail_shell.dart';
import '../widgets/details/details_page.dart';
import '../widgets/details/show_auto_download_controls.dart';
import '../widgets/editorial/editorial.dart';
import '../widgets/media/hue_backdrop.dart';
import '../widgets/media/local_playback.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/media/next_episode_chip.dart';
import '../widgets/mediahub_backdrop_hero.dart';
import '../widgets/mediahub_episodes_drawer.dart';
import '../widgets/mediahub_torrent_drawer.dart';
import '_details_playback_controller.dart';
import 'settings_screen.dart';
import 'video_player_screen.dart';

/// A TV show: the hero, its episodes (in a drawer), overview, automatic
/// download settings, cast and similar shows.
class ShowDetailsScreen extends ConsumerStatefulWidget {
  final Show show;

  /// When true, the episodes drawer opens as soon as the show has loaded.
  /// Used by the browse spotlight's "Stream" action — one click from the
  /// hero to picking an episode.
  final bool autoOpenEpisodesDrawer;

  const ShowDetailsScreen({
    super.key,
    required this.show,
    this.autoOpenEpisodesDrawer = false,
  });

  @override
  ConsumerState<ShowDetailsScreen> createState() => _ShowDetailsScreenState();
}

class _ShowDetailsScreenState extends ConsumerState<ShowDetailsScreen>
    with DetailsPlaybackController<ShowDetailsScreen> {
  bool _autoDrawerFired = false;

  @override
  void dispose() {
    disposePlaybackController();
    super.dispose();
  }

  void _openSettings() => unawaited(
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
  );

  /// Slide the episodes drawer in. It stays open behind the source picker,
  /// so closing the picker lands back on the same episode list.
  Future<void> _openEpisodesDrawer(Show show, List<Season> seasons) async {
    if (seasons.isEmpty) return;
    final tabs = MediaHubEpisodesDrawer.tabSeasons(seasons);
    await MediaHubEpisodesDrawer.open(
      context: context,
      show: show,
      seasons: seasons,
      initialSeason: tabs.isEmpty ? seasons.first.seasonNumber : tabs.first,
      onEpisodeTap: (episode) => unawaited(_onEpisodeTap(episode, show)),
    );
  }

  Future<void> _onEpisodeTap(Episode episode, Show show) async {
    // Finished on disk? Play it — the drawer says "Play" for exactly these.
    // "Finished" is checked here, once, before anything else; a mere
    // existence check matches qBittorrent's pre-allocated shells, and
    // playing one hands mpv a file of zeros.
    final localFile = ref.read(
      episodeLocalFileProvider((
        showName: show.name,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
      )),
    );
    if (localFile != null) {
      final complete = await isFileCompleteOnDisk(ref, localFile);
      if (!mounted) return;
      // Still downloading, but already streaming? Hand the player that
      // session rather than asking for a source all over again.
      final session = complete
          ? null
          : streamingSessionFor(ref.read(streamingSessionsProvider), localFile);
      if (complete || session != null) {
        unawaited(
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => VideoPlayerScreen.fromSession(
                file: session?.videoFile ?? localFile,
                session: session,
                showImdbId: show.imdbId,
              ),
            ),
          ),
        );
        return;
      }
    }
    if (!mounted) return;
    await _openSources(episode, show);
  }

  /// Look up [episode]'s sources and open the picker.
  Future<void> _openSources(Episode episode, Show show) async {
    final imdbId = show.imdbId;
    if (imdbId == null) {
      AppSnackBar.showError(
        context,
        message:
            "Sources can't be looked up for this show — TMDB doesn't link "
            'it to IMDb.',
      );
      return;
    }

    // Straight to the service: the cached provider retries a failure for
    // ~40 s before reporting it, which read as a dead click.
    final torrentio = ref.read(torrentioApiServiceProvider);
    final List<TorrentioStream> streams;
    try {
      streams = (await torrentio.getSeriesStreams(
        imdbId,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
      )).streams;
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.showError(
        context,
        message: friendlyErrorMessage(e, subject: 'sources'),
      );
      return;
    }
    if (!mounted) return;

    if (streams.isEmpty) {
      AppSnackBar.showInfo(
        context,
        message: 'No sources found for ${episode.episodeCode} yet.',
      );
      return;
    }

    await MediaHubTorrentDrawer.show(
      context: context,
      title: show.name,
      subtitle: episode.episodeCode,
      streams: streams,
      onSelect: (stream, isStreaming) {
        if (mounted) {
          unawaited(_play(stream, episode, show, isStreaming: isStreaming));
        }
      },
    );
  }

  /// What the picker's choice does — stream or download — through the flow
  /// the movie page shares ([startDetailsDownload]).
  Future<void> _play(
    TorrentioStream stream,
    Episode episode,
    Show show, {
    required bool isStreaming,
  }) {
    final autoDownload = ref.read(autoDownloadServiceProvider);
    final packFile = stream.isSeasonPack ? stream.fileIdx : null;
    return startDetailsDownload(
      stream: stream,
      isStreaming: isStreaming,
      // [_onEpisodeTap] checked the copy on disk already — once is enough.
      localFile: null,
      showImdbId: show.imdbId,
      episodeCode: episode.episodeCode,
      // A season pack downloads only the episode asked for — through the
      // helper auto-download uses, which waits for the pack's file list.
      onTorrentAdded: packFile == null
          ? null
          : () async {
              await autoDownload.selectEpisodeFile(stream.infoHash, packFile);
            },
      target: DetailsStreamTarget(
        label: '${show.name} ${episode.episodeCode}',
        packLabel: 'season pack',
        showName: show.name,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
        onTryAnotherSource: () => unawaited(_openSources(episode, show)),
        openPlayer: (file, session) => VideoPlayerScreen.fromSession(
          file: file,
          session: session,
          showImdbId: show.imdbId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showAsync = ref.watch(showDetailsProvider(widget.show.id));

    // From the browse spotlight: open the drawer once the show is in.
    final loaded = showAsync.value;
    if (widget.autoOpenEpisodesDrawer &&
        !_autoDrawerFired &&
        loaded != null &&
        loaded.seasons.isNotEmpty) {
      _autoDrawerFired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openEpisodesDrawer(loaded, loaded.seasons));
      });
    }

    return DetailsPageScaffold<Show>(
      value: showAsync,
      subject: 'this show',
      onRetry: () => ref.invalidate(showDetailsProvider(widget.show.id)),
      onOpenSettings: _openSettings,
      headerActions: (show) => Consumer(
        builder: (context, ref, _) => DetailsHeaderActions(
          isFavorite: ref.watch(isFavoriteProvider(show.id)),
          onToggleFavorite: () => unawaited(
            ref
                .read(favoritesProvider.notifier)
                .toggleFavorite(show.id, show: show),
          ),
          isOnWatchlist: ref.watch(isOnWatchlistProvider(show.id)),
          onToggleWatchlist: () => unawaited(
            ref.read(watchlistProvider.notifier).toggleShow(show.id),
          ),
          onOpenSettings: _openSettings,
        ),
      ),
      builder: (context, show) => _content(show),
    );
  }

  Widget _content(Show show) {
    final similar = ref.watch(similarShowsProvider(show.id)).value ?? const [];
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _hero(show)),
        DetailsOverviewSliver(overview: show.overview),
        SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.detailPadding,
                  top: AppSpacing.xl,
                  right: AppSpacing.detailPadding,
                ),
                child: ShowAutoDownloadControls(showId: show.id),
              ),
            ),
          ),
        ),
        DetailsCastSliver(cast: show.cast),
        DetailsSimilarSliver(
          itemCount: similar.length,
          itemBuilder: (context, index) {
            final other = similar[index];
            return MediaPosterCard.show(
              other,
              width: DetailsSimilarSliver.cardWidth,
              onTap: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ShowDetailsScreen(show: other),
                  ),
                ),
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
      ],
    );
  }

  Widget _hero(Show show) {
    final rating = ratingLabel(show.voteAverage, voteCount: show.voteCount);
    final seasons = show.numberOfSeasons;
    final episodes = show.numberOfEpisodes;
    return MediaHubBackdropHero(
      title: show.name,
      year: show.year,
      posterUrl: show.posterUrl,
      backdropUrl: show.backdropUrl,
      fallbackHue: hueForId(show.id),
      // The tagline, not the overview: the synopsis is the Overview section
      // just below, and printing it twice put the same text on the page twice.
      description: show.tagline,
      statusOverlay: NextEpisodeChip(show: show),
      posterPlaceholderIcon: Icons.live_tv_rounded,
      metaPills: [
        if (show.statusLabel != null)
          MediaHubMetaPill(label: show.statusLabel!, color: AppColors.warn),
        if (seasons != null)
          MediaHubMetaPill(
            label: seasons == 1 ? '1 season' : '$seasons seasons',
            color: AppColors.fg1,
          ),
        if (show.episodeRunTime != null && show.episodeRunTime!.isNotEmpty)
          MediaHubMetaPill(
            label: '~${show.episodeRunTime!.first} min',
            color: AppColors.fg1,
          ),
        if (episodes != null)
          MediaHubMetaPill(
            label: episodes == 1 ? '1 episode' : '$episodes episodes',
            color: AppColors.fg1,
          ),
        if (rating != null)
          MediaHubMetaPill(
            label: rating,
            color: getRatingColor(show.voteAverage),
          ),
        ...show.genres
            .take(2)
            .map((g) => MediaHubMetaPill(label: g, color: AppColors.accent)),
      ],
      // The single way into the episode list.
      primaryAction: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          if (show.seasons.isNotEmpty)
            EditorialButton(
              label: 'Browse episodes',
              icon: Icons.play_arrow_rounded,
              kind: EditorialButtonKind.accent,
              large: true,
              onPressed: () =>
                  unawaited(_openEpisodesDrawer(show, show.seasons)),
            )
          else
            // Said, not hidden behind a button that never enables: TMDB
            // lists no seasons for a show that is only announced.
            EditorialButton(
              label: 'No episodes listed yet · Check again',
              icon: Icons.refresh_rounded,
              kind: EditorialButtonKind.ghost,
              large: true,
              onPressed: () => ref.invalidate(showDetailsProvider(show.id)),
            ),
          if (bestTrailer(show.videos) != null)
            TrailerButton(videos: show.videos),
        ],
      ),
    );
  }
}
