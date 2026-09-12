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
import '../providers/connection_provider.dart' as connection_provider;
import '../providers/eztv_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/torrentio_provider.dart';
import '../providers/watchlist_provider.dart';
import '../services/app_logger.dart';
import '../services/library_actions.dart';
import '../utils/feedback_utils.dart';
import '../widgets/common/floating_header_action.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/details/show_detail_sections.dart';
import '../widgets/media/cast_row.dart';
import '../widgets/media/next_episode_chip.dart';
import '../widgets/media/trailers_row.dart';
import '../widgets/mediahub_backdrop_hero.dart';
import '../widgets/mediahub_episodes_drawer.dart';
import '../widgets/mediahub_torrent_drawer.dart';
import '_details_playback_controller.dart';
import 'settings_screen.dart';
import 'video_player_screen.dart';

/// Screen for displaying TV show details with seasons and episodes
class ShowDetailsScreen extends ConsumerStatefulWidget {
  final Show show;

  /// When true, the episodes drawer fires automatically as soon as the
  /// season list resolves. Used by the browse spotlight's primary CTA
  /// to give users a one-tap path from the hero to episode selection.
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
  bool _isLoadingTorrents = false;
  bool _autoDrawerFired = false;
  // Streaming overlay + subscription lifecycle (streamingOverlay,
  // streamingOverlayData, monitorSubscription) lives on
  // DetailsPlaybackController; tear down via disposePlaybackController().

  @override
  void initState() {
    super.initState();
    _loadTorrentAvailability();
  }

  @override
  void dispose() {
    disposePlaybackController();
    super.dispose();
  }

  Future<void> _loadTorrentAvailability() async {
    final showDetails = await ref.read(
      showDetailsProvider(widget.show.id).future,
    );
    if (showDetails.imdbId == null) return;

    setState(() => _isLoadingTorrents = true);

    try {
      // Probe Torrentio cache so the "Browse episodes" CTA can stop
      // showing its loading spinner once we know what's available.
      await ref.read(
        checkTorrentAvailabilityProvider(showDetails.imdbId!).future,
      );
      if (mounted) {
        setState(() => _isLoadingTorrents = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingTorrents = false);
      }
    }
  }

  /// Slide the episodes drawer in from the right. Each tap inside
  /// the drawer fires the same `_onEpisodeTap` flow that the old
  /// inline list used.
  Future<void> _openEpisodesDrawer(Show show, List<Season> seasons) async {
    if (seasons.isEmpty) return;
    final firstAired = seasons.firstWhere(
      (s) => s.seasonNumber > 0,
      orElse: () => seasons.first,
    );
    await MediaHubEpisodesDrawer.open(
      context: context,
      show: show,
      seasons: seasons,
      initialSeason: firstAired.seasonNumber,
      // Keep the episodes drawer open behind the torrent picker so
      // when the user closes the picker they land back in the same
      // season/episode list — no need to re-open from scratch.
      onEpisodeTap: (episode) => _onEpisodeTap(episode, show),
    );
  }

  Future<void> _onEpisodeTap(Episode episode, Show showDetails) async {
    // Fully downloaded? Play it. The drawer labels these rows OPEN / REWATCH
    // rather than GET, and sending them to the source picker instead
    // contradicts the button the user just pressed.
    //
    // "Fully downloaded" is the operative word — see [isFileCompleteOnDisk].
    // A mere existence check matches qBittorrent's pre-allocated shells, and
    // playing one of those hands mpv a file of zeros.
    final localFile = ref.read(
      episodeLocalFileProvider((
        showName: showDetails.name,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
      )),
    );
    if (localFile != null && await isFileCompleteOnDisk(ref, localFile)) {
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            file: localFile,
            showImdbId: showDetails.imdbId,
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    if (showDetails.imdbId == null) {
      AppSnackBar.showError(
        context,
        message: 'IMDB ID not available for this show',
      );
      return;
    }

    // Load Torrentio streams for this episode
    try {
      final response = await ref.read(
        seriesStreamsProvider((
          imdbId: showDetails.imdbId!,
          season: episode.seasonNumber,
          episode: episode.episodeNumber,
        )).future,
      );

      if (response.streams.isEmpty) {
        if (mounted) {
          AppSnackBar.showInfo(
            context,
            message: 'No streams available for this episode',
          );
        }
        return;
      }

      if (mounted) {
        await MediaHubTorrentDrawer.show(
          context: context,
          title: showDetails.name,
          subtitle: episode.episodeCode,
          streams: response.streams,
          onSelect: (stream, isStreaming) => _downloadStream(
            stream,
            episode,
            showDetails,
            isStreaming: isStreaming,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.showError(context, message: 'Failed to load streams: $e');
      }
    }
  }

  Future<void> _downloadStream(
    TorrentioStream stream,
    Episode episode,
    Show show, {
    bool isStreaming = false,
  }) async {
    final connectionState = ref.read(connection_provider.connectionProvider);

    // Use the global ScaffoldMessenger to ensure SnackBar persists across navigation
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null) return;

    try {
      if (!connectionState.isConnected) {
        AppSnackBar.showOn(
          messenger,
          message: 'Not connected to the torrent engine',
          kind: AppSnackBarKind.warning,
        );
        return;
      }

      // Store ref for the SnackBar action callback
      final containerRef = ProviderScope.containerOf(context);

      // Hide any existing SnackBar first
      messenger.hideCurrentSnackBar();

      if (isStreaming) {
        // Local-first: if the user already has this episode on disk,
        // play directly. Skips the entire torrent + buffer dance — qBit
        // doesn't necessarily know about a previously-downloaded file
        // that was removed from its session, and re-adding the magnet
        // would force a full re-check or even a re-download.
        final localFile = ref.read(
          episodeLocalFileProvider((
            showName: show.name,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
          )),
        );
        if (localFile != null && await isFileCompleteOnDisk(ref, localFile)) {
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) =>
                  VideoPlayerScreen(file: localFile, showImdbId: show.imdbId),
            ),
          );
          return;
        }

        // Use the streaming service for robust streaming
        await _startStreamingSession(stream, episode, show);
      } else {
        // Regular download
        final apiService = ref.read(connection_provider.torrentEngineProvider);

        final success = await apiService.addTorrent(
          magnetLink: stream.magnetUri,
          sequentialDownload: false,
          firstLastPiecePrio: false,
        );

        if (!success) {
          AppSnackBar.showOn(
            messenger,
            message: 'Failed to start download',
            kind: AppSnackBarKind.error,
          );
          return;
        }

        // If this is a season pack, set file priorities
        if (stream.isSeasonPack && stream.fileIdx != null) {
          // Deliberately not awaited: this waits on torrent metadata, which
          // can take tens of seconds. The snackbar below should confirm the
          // add immediately rather than after file selection resolves.
          unawaited(_selectFileFromSeasonPack(stream));
        }

        AppSnackBar.showOn(
          messenger,
          message:
              'Started downloading ${episode.episodeCode}'
              '${stream.isSeasonPack ? " (from pack)" : ""}',
          kind: AppSnackBarKind.success,
          actionLabel: 'View Downloads',
          onAction: () {
            messenger.hideCurrentSnackBar();
            containerRef.read(currentTabIndexProvider.notifier).set(1);
            rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
          },
        );
      }
    } catch (e) {
      AppSnackBar.showOn(
        messenger,
        message: 'Failed to start download: $e',
        kind: AppSnackBarKind.error,
      );
    }
  }

  /// Start a streaming session with the floating progress overlay.
  ///
  /// Everything below the [DetailsStreamTarget] is shared with
  /// `movie_details_screen.dart` via [DetailsPlaybackController].
  Future<void> _startStreamingSession(
    TorrentioStream stream,
    Episode episode,
    Show show,
  ) async {
    await startDetailsStream(
      stream: stream,
      showImdbId: show.imdbId,
      episodeCode: episode.episodeCode,
      target: DetailsStreamTarget(
        label: episode.episodeCode,
        packLabel: 'season pack',
        showName: show.name,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
        openPlayer: (file, session) => VideoPlayerScreen(
          file: file,
          showImdbId: show.imdbId,
          isStreaming: session != null,
          streamingTorrentHash: session?.torrentHash,
          streamingFileIndex: session?.selectedFileIndex,
          streamingProxyUrl: session?.streamUrl,
          initialBufferedRatio: session?.bufferProgress,
          streamingSessionId: session?.id,
        ),
      ),
    );
  }

  /// Select only the target file from a season pack
  Future<void> _selectFileFromSeasonPack(TorrentioStream stream) async {
    if (stream.fileIdx == null) return;

    final apiService = ref.read(connection_provider.torrentEngineProvider);

    // Wait for metadata to be available
    await Future.delayed(const Duration(seconds: 3));

    try {
      var files = await apiService.getTorrentFiles(stream.infoHash);
      if (files.isEmpty) {
        // Retry after more delay. The retry result used to be assigned to a
        // local that nothing below then read, so the whole block below ran
        // against the empty first list: `allFileIds` was empty and the
        // bounds check `fileIdx < 0` failed. The retry did nothing at all.
        await Future.delayed(const Duration(seconds: 3));
        files = await apiService.getTorrentFiles(stream.infoHash);
        if (files.isEmpty) {
          AppLog.d(
            '[ShowDetails] No files found in torrent, cannot select specific file',
          );
          return;
        }
      }

      // Skip only the incomplete extras — same rule as StreamingService.
      // Zeroing an already-finished file can flip qBittorrent into a recheck.
      final skipIds = [
        for (var i = 0; i < files.length; i++)
          if (i != stream.fileIdx && files[i].progress < 0.999) i,
      ];
      if (skipIds.isNotEmpty) {
        await apiService.setFilePriority(stream.infoHash, skipIds, 0);
      }

      // Set target file to high priority
      if (stream.fileIdx! < files.length) {
        await apiService.setFilePriority(stream.infoHash, [stream.fileIdx!], 7);
        AppLog.d(
          '[ShowDetails] Selected file ${stream.fileIdx} from season pack',
        );
      }
    } catch (e) {
      AppLog.e('[ShowDetails] Error selecting file from season pack: $e');
    }
  }

  /// Monitor a streaming session and open player when ready.
  ///
  /// Uses a [StreamSubscription] (not `await for`) so the monitor
  /// keeps running even if the user navigates away from this screen.
  /// Navigation is done via [rootNavigatorKey] — no [mounted] check needed.
  @override
  Widget build(BuildContext context) {
    final showDetails = ref.watch(showDetailsProvider(widget.show.id));
    final seasons = ref.watch(showSeasonsProvider(widget.show.id));
    final isFavorite = ref.watch(isFavoriteProvider(widget.show.id));

    // When opened from the browse spotlight, open the episodes drawer
    // automatically as soon as both the show + seasons resolve.
    if (widget.autoOpenEpisodesDrawer && !_autoDrawerFired) {
      final ready = showDetails.hasValue && seasons.hasValue;
      if (ready) {
        _autoDrawerFired = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _openEpisodesDrawer(showDetails.value!, seasons.value!);
        });
      }
    }

    return Scaffold(
      body: showDetails.when(
        data: (show) => _buildContent(show, seasons, isFavorite),
        loading: () => const LoadingIndicator(),
        error: (error, _) => Center(child: Text('Error: $error')),
      ),
    );
  }

  Widget _buildContent(
    Show show,
    AsyncValue<List<Season>> seasons,
    bool isFavorite,
  ) {
    // Constrain main-page content to a comfortable reading width so
    // text + cards don't sprawl the full viewport on wide windows.
    Widget contentSliver(Widget child, {EdgeInsets? padding}) {
      return SliverToBoxAdapter(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: Padding(
              padding:
                  padding ??
                  const EdgeInsets.fromLTRB(
                    AppSpacing.screenPadding,
                    AppSpacing.xl,
                    AppSpacing.screenPadding,
                    0,
                  ),
              child: child,
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            // Cinematic backdrop hero — left full-bleed.
            _buildSliverAppBar(show, isFavorite, seasons),

            // Next-episode card (renders only when nextEpisodeToAir set).
            contentSliver(_buildShowInfo(show), padding: EdgeInsets.zero),

            // Browse Episodes CTA — opens the right-side drawer.
            contentSliver(
              BrowseEpisodesCta(
                show: show,
                seasons: seasons,
                loadingTorrents: _isLoadingTorrents,
                onOpen: (seasonList) => _openEpisodesDrawer(show, seasonList),
              ),
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.screenPadding,
                AppSpacing.lg,
                AppSpacing.screenPadding,
                0,
              ),
            ),

            // Trailers + Cast — full-bleed slivers (their internal headers
            // handle the screen padding, the horizontal scrollers extend
            // edge-to-edge).
            if (show.videos.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xxl),
                  child: TrailersRow(videos: show.videos),
                ),
              ),
            if (show.cast.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xxl),
                  child: CastRow(cast: show.cast),
                ),
              ),

            // Storyline + Quick facts in a two-column layout when wide,
            // single-column when narrow.
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screenPadding,
                      AppSpacing.xl,
                      AppSpacing.screenPadding,
                      0,
                    ),
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final twoCol = c.maxWidth >= 800;
                        final storyline =
                            show.overview != null && show.overview!.isNotEmpty
                            ? InfoSection(
                                title: 'Storyline',
                                child: Text(
                                  show.overview!,
                                  style: const TextStyle(
                                    color: AppColors.fg1,
                                    fontSize: 14,
                                    height: 1.6,
                                  ),
                                ),
                              )
                            : null;
                        final facts = InfoSection(
                          title: 'Quick facts',
                          child: QuickFactsGrid(show: show),
                        );
                        if (twoCol) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (storyline != null) ...[
                                Expanded(flex: 5, child: storyline),
                                const SizedBox(width: AppSpacing.xl),
                              ],
                              Expanded(flex: 4, child: facts),
                            ],
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (storyline != null) ...[
                              storyline,
                              const SizedBox(height: AppSpacing.xl),
                            ],
                            facts,
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),

            // Bottom padding
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.huge)),
          ],
        ),
        _buildFloatingHeaderControls(show, isFavorite),
      ],
    );
  }

  Widget _buildSliverAppBar(
    Show show,
    bool isFavorite,
    AsyncValue<List<Season>> seasons,
  ) {
    // Cinematic MediaHub backdrop hero — full-bleed image, big
    // display title, mono metadata pills. Floating back/favorite/etc
    // overlays now live at the screen level (see _buildContent) so they
    // stay pinned during scroll.
    return SliverToBoxAdapter(
      child: MediaHubBackdropHero(
        title: show.name,
        year: show.year,
        posterUrl: show.posterUrl,
        backdropUrl: show.backdropUrl,
        fallbackHue: (show.id * 37 % 360).toDouble(),
        description: show.overview,
        posterPlaceholderIcon: Icons.live_tv_rounded,
        metaPills: [
          if (show.statusLabel != null)
            MediaHubMetaPill(
              label: show.statusLabel!,
              color: AppColors.accentAmber,
            ),
          if (show.numberOfSeasons != null)
            MediaHubMetaPill(
              label:
                  '${show.numberOfSeasons} ${show.numberOfSeasons == 1 ? "SEASON" : "SEASONS"}',
              color: AppColors.fg1,
            ),
          if (show.numberOfEpisodes != null)
            MediaHubMetaPill(
              label: '${show.numberOfEpisodes} EP',
              color: AppColors.fg1,
            ),
          if (show.voteAverage > 0)
            MediaHubMetaPill(
              label: '★ ${show.voteAverage.toStringAsFixed(1)}',
              color: getRatingColor(show.voteAverage),
            ),
          ...show.genres
              .take(2)
              .map(
                (g) =>
                    MediaHubMetaPill(label: g, color: AppColors.accentPrimary),
              ),
        ],
        primaryAction: FilledButton.icon(
          onPressed: seasons.hasValue && seasons.value!.isNotEmpty
              ? () => _openEpisodesDrawer(show, seasons.value!)
              : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Browse episodes'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.md,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingHeaderControls(Show show, bool isFavorite) {
    return Stack(
      children: [
        // Floating back button — overlaid in the top-left. Stays pinned
        // regardless of scroll position because it's a screen-level
        // overlay rather than part of the scrolling sliver.
        Positioned(
          top: AppSpacing.lg,
          left: AppSpacing.xxl,
          child: SafeArea(
            child: FloatingHeaderAction(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
        Positioned(
          top: AppSpacing.lg,
          right: AppSpacing.xxl,
          child: SafeArea(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingHeaderAction(
                  icon: isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  iconColor: isFavorite ? Colors.redAccent : Colors.white,
                  tooltip: isFavorite
                      ? 'Remove from favorites'
                      : 'Add to favorites',
                  onPressed: () {
                    ref
                        .read(favoritesProvider.notifier)
                        .toggleFavorite(show.id, show: show);
                  },
                ),
                const SizedBox(width: AppSpacing.xs),
                Consumer(
                  builder: (context, ref, _) {
                    final onWatchlist = ref.watch(
                      isOnWatchlistProvider(show.id),
                    );
                    return FloatingHeaderAction(
                      icon: onWatchlist
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_outline_rounded,
                      iconColor: onWatchlist
                          ? Colors.amberAccent
                          : Colors.white,
                      tooltip: onWatchlist
                          ? 'Remove from watchlist'
                          : 'Add to watchlist',
                      onPressed: () => ref
                          .read(watchlistProvider.notifier)
                          .toggleShow(show.id),
                    );
                  },
                ),
                const SizedBox(width: AppSpacing.xs),
                FloatingHeaderAction(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildShowInfo(Show show) {
    // NextEpisodeChip handles its own visibility: returns SizedBox.shrink
    // when the show has no scheduled / recently-aired episode. The chip
    // also covers the "recently aired" case which the old primitive
    // upcoming-only card missed.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        AppSpacing.lg,
        AppSpacing.screenPadding,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [NextEpisodeChip(show: show)],
      ),
    );
  }
}
