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
import '../widgets/details/detail_shell.dart';
import '../widgets/details/show_detail_sections.dart';
import '../widgets/editorial/serif_title.dart';
import '../widgets/media/cast_row.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/media/next_episode_chip.dart';
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
    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            // Cinematic backdrop hero — left full-bleed.
            _buildSliverAppBar(show, isFavorite, seasons),

            // Storyline.
            //
            // What used to sit here alongside it was a bordered "Quick facts"
            // table: first aired, status, seasons, episodes, genres, rating.
            // Six of those eight rows restated a pill in the hero a few
            // hundred pixels above — the same facts, in a heavier treatment,
            // costing ~380px and most of the page's scroll. The two it did not
            // duplicate were the episode runtime, now a pill like the rest,
            // and "last aired", which the next-episode chip already covers.
            if (show.overview != null && show.overview!.isNotEmpty)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.detailPadding,
                        AppSpacing.xl,
                        AppSpacing.detailPadding,
                        0,
                      ),
                      child: InfoSection(
                        title: 'Storyline',
                        child: Text(
                          show.overview!,
                          style: const TextStyle(
                            color: AppColors.fg1,
                            fontSize: 14,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Cast — folded away by default.
            if (show.cast.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: FoldableSection(
                    title: 'Cast',
                    count:
                        '${show.cast.length > 12 ? '12+' : show.cast.length} '
                        'CREDITS',
                    child: CastRow(cast: show.cast, showHeader: false),
                  ),
                ),
              ),

            // Suggestions — peripheral by design: dimmed until pointed at.
            _similarSliver(show),

            // Bottom padding
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
          ],
        ),
        _buildFloatingHeaderControls(show, isFavorite),
      ],
    );
  }

  /// Suggestions, at the bottom and deliberately quiet.
  ///
  /// A row of other shows is peripheral: the reader came here for *this* one.
  /// It sits dimmed until the pointer arrives, then comes up to full strength
  /// with scroll arrows — present when there is more in that direction, absent
  /// when there is not.
  Widget _similarSliver(Show show) {
    final similar = ref.watch(similarShowsProvider(show.id));
    return similar.maybeWhen(
      data: (shows) => shows.isEmpty
          ? const SliverToBoxAdapter(child: SizedBox.shrink())
          : SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xxl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.detailPadding,
                        0,
                        AppSpacing.detailPadding,
                        AppSpacing.md,
                      ),
                      child: SerifTitle(
                        'More like this',
                        size: 22,
                        height: 1.0,
                      ),
                    ),
                    HoverScrollRow(
                      height: 196,
                      itemCount: shows.length,
                      itemBuilder: (context, index) {
                        final other = shows[index];
                        return MediaPosterCard(
                          title: other.name,
                          width: 124,
                          posterAsync: AsyncValue.data(other.posterUrl),
                          titleStyle: CardTitleStyle.overlay,
                          overlayYear: other.year,
                          overlayRating: other.voteAverage > 0
                              ? '★ ${other.voteAverage.toStringAsFixed(1)}'
                              : null,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ShowDetailsScreen(show: other),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
      orElse: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
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
        // The tagline, not the overview: the full synopsis is the Storyline
        // section further down, and printing it in both places put the same
        // text on the page twice.
        description: show.tagline,
        statusOverlay: NextEpisodeChip(show: show),
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
          if (show.episodeRunTime != null && show.episodeRunTime!.isNotEmpty)
            MediaHubMetaPill(
              label: '~${show.episodeRunTime!.first} MIN',
              color: AppColors.fg1,
            ),
          if (show.numberOfEpisodes != null)
            MediaHubMetaPill(
              // Spelled out, to match "4 SEASONS" sitting right beside it.
              label:
                  '${show.numberOfEpisodes} '
                  '${show.numberOfEpisodes == 1 ? "EPISODE" : "EPISODES"}',
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
        // The single way into the episode list.
        //
        // There used to be a second one: a full-width card below the hero,
        // with the same label, the same action, and a subtitle repeating the
        // season and episode counts that are already meta pills a few pixels
        // above it. Two controls for one action is a question the reader has
        // to answer ("do these differ?") before they can act.
        //
        // The card's one unique signal was the Torrentio cache probe, which
        // is why the button spins rather than simply being dropped.
        primaryAction: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: seasons.hasValue && seasons.value!.isNotEmpty
                  ? () => _openEpisodesDrawer(show, seasons.value!)
                  : null,
              icon: _isLoadingTorrents
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black54,
                      ),
                    )
                  : const Icon(Icons.play_arrow_rounded),
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
            if (bestTrailer(show.videos) != null) ...[
              const SizedBox(width: AppSpacing.sm),
              TrailerButton(videos: show.videos),
            ],
          ],
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
}
