import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/local_media_file.dart';
import '../models/show.dart';
import '../models/season.dart';
import '../models/episode.dart';
import '../models/torrentio_stream.dart';
import '../providers/connection_provider.dart' as connection_provider;
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/watchlist_provider.dart';
import '../providers/torrentio_provider.dart';
import '../providers/eztv_provider.dart';
import '../providers/streaming_provider.dart';
import '../services/streaming_service.dart';
import '../utils/feedback_utils.dart';
import '../utils/formatters.dart';
import '../widgets/common/floating_header_action.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/media/cast_row.dart';
import '../widgets/media/next_episode_chip.dart';
import '../widgets/media/trailers_row.dart';
import '../widgets/mediahub_backdrop_hero.dart';
import '_details_playback_controller.dart';
import '../widgets/mediahub_episodes_drawer.dart';
import '../widgets/mediahub_torrent_drawer.dart';
import '../widgets/streaming_progress_overlay.dart';
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load streams: $e')));
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
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Not connected to qBittorrent'),
            duration: Duration(seconds: 3),
          ),
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
        if (localFile != null && File(localFile.path).existsSync()) {
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
        final apiService = ref.read(connection_provider.qbApiServiceProvider);

        final success = await apiService.addTorrent(
          magnetLink: stream.magnetUri,
          sequentialDownload: false,
          firstLastPiecePrio: false,
        );

        if (!success) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Failed to start download'),
              duration: Duration(seconds: 3),
            ),
          );
          return;
        }

        // If this is a season pack, set file priorities
        if (stream.isSeasonPack && stream.fileIdx != null) {
          // Wait for metadata then select only the target file
          _selectFileFromSeasonPack(stream);
        }

        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Started downloading ${episode.episodeCode}${stream.isSeasonPack ? " (from pack)" : ""}',
            ),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'View Downloads',
              textColor: Colors.white,
              onPressed: () {
                messenger.hideCurrentSnackBar();
                containerRef.read(currentTabIndexProvider.notifier).set(1);
                rootNavigatorKey.currentState?.popUntil(
                  (route) => route.isFirst,
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to start download: $e'),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// Start a streaming session using the new StreamingService
  Future<void> _startStreamingSession(
    TorrentioStream stream,
    Episode episode,
    Show show,
  ) async {
    final containerRef = ProviderScope.containerOf(context);

    // Show initial streaming overlay (updatable, so _monitorStreamingSession
    // can update it in-place without replaying the entrance animation).
    final isSingleFile = stream.isSingleFile;
    streamingOverlay?.remove();
    streamingOverlayData?.dispose();

    final result = showUpdatableStreamingOverlay(
      context,
      title: 'Starting ${episode.episodeCode}',
      subtitle: isSingleFile
          ? 'Connecting...'
          : 'Selecting from season pack...',
      isIndeterminate: true,
      showClose: true,
      onClose: () {
        streamingOverlay = null;
        streamingOverlayData = null;
      },
      onViewDownloads: () {
        streamingOverlay?.remove();
        streamingOverlay = null;
        streamingOverlayData?.dispose();
        streamingOverlayData = null;
        containerRef.read(currentTabIndexProvider.notifier).set(1);
        rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      },
    );
    streamingOverlay = result.entry;
    streamingOverlayData = result.data;

    final session = await ref
        .read(streamingSessionsProvider.notifier)
        .startStreaming(
          stream: stream,
          showImdbId: show.imdbId,
          showName: show.name,
          season: episode.seasonNumber,
          episode: episode.episodeNumber,
          episodeCode: episode.episodeCode,
        );

    if (session == null) {
      streamingOverlay?.remove();
      streamingOverlay = null;

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Failed to start streaming session'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    // Monitor the session for readiness
    _monitorStreamingSession(session.id, episode, show);
  }

  /// Select only the target file from a season pack
  Future<void> _selectFileFromSeasonPack(TorrentioStream stream) async {
    if (stream.fileIdx == null) return;

    final apiService = ref.read(connection_provider.qbApiServiceProvider);

    // Wait for metadata to be available
    await Future.delayed(const Duration(seconds: 3));

    try {
      final files = await apiService.getTorrentFiles(stream.infoHash);
      if (files.isEmpty) {
        // Retry after more delay
        await Future.delayed(const Duration(seconds: 3));
        final retryFiles = await apiService.getTorrentFiles(stream.infoHash);
        if (retryFiles.isEmpty) {
          debugPrint(
            '[ShowDetails] No files found in torrent, cannot select specific file',
          );
          return;
        }
      }

      // Set all files to skip (priority 0)
      final allFileIds = List.generate(files.length, (i) => i);
      await apiService.setFilePriority(stream.infoHash, allFileIds, 0);

      // Set target file to high priority
      if (stream.fileIdx! < files.length) {
        await apiService.setFilePriority(stream.infoHash, [stream.fileIdx!], 7);
        debugPrint(
          '[ShowDetails] Selected file ${stream.fileIdx} from season pack',
        );
      }
    } catch (e) {
      debugPrint('[ShowDetails] Error selecting file from season pack: $e');
    }
  }

  /// Monitor a streaming session and open player when ready.
  ///
  /// Uses a [StreamSubscription] (not `await for`) so the monitor
  /// keeps running even if the user navigates away from this screen.
  /// Navigation is done via [rootNavigatorKey] — no [mounted] check needed.
  void _monitorStreamingSession(String sessionId, Episode episode, Show show) {
    final containerRef = ProviderScope.containerOf(context);

    // Reuse the overlay created by _startStreamingSession if it's already up;
    // otherwise create one (e.g. when called from a different entry point).
    if (mounted && streamingOverlayData != null) {
      streamingOverlayData!.value = StreamingOverlayData(
        title: 'Preparing ${episode.episodeCode}',
        subtitle: episode.name,
        isIndeterminate: true,
      );
    } else if (mounted) {
      final result = showUpdatableStreamingOverlay(
        context,
        title: 'Preparing ${episode.episodeCode}',
        subtitle: episode.name,
        isIndeterminate: true,
        showClose: true,
        onClose: () {
          streamingOverlay = null;
          streamingOverlayData = null;
        },
        onViewDownloads: () {
          streamingOverlay?.remove();
          streamingOverlay = null;
          streamingOverlayData?.dispose();
          streamingOverlayData = null;
          containerRef.read(currentTabIndexProvider.notifier).set(1);
          rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        },
      );
      streamingOverlay = result.entry;
      streamingOverlayData = result.data;
    }

    // Listen to the *notifier's* state instead of the streaming service's
    // broadcast stream. The notifier already subscribes to the broadcast
    // once and updates its state on every emit, so by watching the notifier
    // we can't miss the early state transitions that happen between
    // startStreaming() returning and the UI subscribing.
    //
    // `fireImmediately: true` makes the listener tick once with the current
    // state — so if the session has already advanced (e.g. fast-path to
    // ready), we react right away.
    monitorSubscription?.close();
    monitorSubscription = ref.listenManual<StreamingSessionsState>(
      streamingSessionsProvider,
      (prev, next) {
        final session = next.sessions[sessionId];
        if (session == null) return;
        _handleSessionState(session, episode, show, containerRef);
      },
      fireImmediately: true,
    );
  }

  void _handleSessionState(
    StreamingSession session,
    Episode episode,
    Show show,
    ProviderContainer containerRef,
  ) {
    switch (session.state) {
      case StreamingState.addingTorrent:
      case StreamingState.selectingFiles:
      case StreamingState.buffering:
        // Update the existing overlay in-place — no remove/recreate, no flicker.
        // Always show actual percentage so the user sees forward motion even
        // during file-selection / metadata phases.
        final pct = session.bufferProgress * 100;
        final titlePrefix = session.state == StreamingState.buffering
            ? 'Buffering'
            : 'Preparing';
        final speed = session.downloadRateBytesPerSec;
        final speedSuffix = speed > 0
            ? ' • ${Formatters.formatSpeed(speed)}'
            : '';
        streamingOverlayData?.value = StreamingOverlayData(
          title: '$titlePrefix ${episode.episodeCode}',
          subtitle: pct > 0
              ? '${pct.toStringAsFixed(1)}% ready$speedSuffix'
              : 'Connecting…$speedSuffix',
          progress: pct > 0 ? session.bufferProgress : null,
          isIndeterminate: pct == 0,
        );

      case StreamingState.ready:
      case StreamingState.playing:
        monitorSubscription?.close();
        streamingOverlay?.remove();
        streamingOverlay = null;
        streamingOverlayData?.dispose();
        streamingOverlayData = null;

        // Clear the active session so the safety-net listener in
        // main_navigation_screen doesn't also open the player.
        containerRef
            .read(streamingSessionsProvider.notifier)
            .clearActiveSession();

        // Navigate via root key — works whether screen is mounted or not
        if (session.videoFile != null) {
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => VideoPlayerScreen(
                file: session.videoFile!,
                showImdbId: show.imdbId,
                isStreaming: true,
                streamingTorrentHash: session.torrentHash,
                streamingFileIndex: session.selectedFileIndex,
                streamingProxyUrl: session.streamUrl,
                initialBufferedRatio: session.bufferProgress,
              ),
            ),
          );
        } else if (session.contentPath != null &&
            session.selectedFilePath != null) {
          // Fallback: open via content path
          if (mounted) {
            _openStreamingPlayer(session.contentPath!, episode, show);
          }
        }

      case StreamingState.error:
        monitorSubscription?.close();
        streamingOverlay?.remove();
        streamingOverlay = null;
        streamingOverlayData?.dispose();
        streamingOverlayData = null;

        rootScaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(
              'Streaming error: ${session.errorMessage ?? "Failed to stream"}',
            ),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );

      case StreamingState.cancelled:
        monitorSubscription?.close();
        streamingOverlay?.remove();
        streamingOverlay = null;
        streamingOverlayData?.dispose();
        streamingOverlayData = null;

      case StreamingState.idle:
        break;
    }
  }

  void _openStreamingPlayer(
    String contentPath,
    Episode episode,
    Show show,
  ) async {
    // Find the video file in the content path
    final videoFile = await _findVideoFile(
      contentPath,
      episode: episode,
      show: show,
    );

    if (videoFile == null) {
      final messenger = rootScaffoldMessengerKey.currentState;
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not find video file in: $contentPath'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) =>
              VideoPlayerScreen(file: videoFile, showImdbId: show.imdbId),
        ),
      );
    }
  }

  Future<LocalMediaFile?> _findVideoFile(
    String contentPath, {
    Episode? episode,
    Show? show,
  }) async {
    try {
      final path = contentPath;
      final fileOrDir = FileSystemEntity.typeSync(path);

      List<File> videoFiles = [];

      if (fileOrDir == FileSystemEntityType.file) {
        // It's a file, check if it's a video
        final ext = path.split('.').last.toLowerCase();
        if (videoExtensions.contains(ext)) {
          videoFiles.add(File(path));
        }
      } else if (fileOrDir == FileSystemEntityType.directory) {
        // Scan directory for video files
        final dir = Directory(path);
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final ext = entity.path.split('.').last.toLowerCase();
            if (videoExtensions.contains(ext)) {
              videoFiles.add(entity);
            }
          }
        }
      }

      if (videoFiles.isEmpty) return null;

      // Pick the largest video file (usually the main content)
      videoFiles.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      final largestFile = videoFiles.first;
      final stat = largestFile.statSync();

      return LocalMediaFile(
        path: largestFile.path,
        fileName: largestFile.path.split(Platform.pathSeparator).last,
        sizeBytes: stat.size,
        modifiedDate: stat.modified,
        extension: largestFile.path.split('.').last.toLowerCase(),
        showName: show?.name,
        seasonNumber: episode?.seasonNumber,
        episodeNumber: episode?.episodeNumber,
      );
    } catch (e) {
      debugPrint('Error finding video file: $e');
      return null;
    }
  }

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
          _BrowseEpisodesCta(
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
                        ? _InfoSection(
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
                    final facts = _InfoSection(
                      title: 'Quick facts',
                      child: _QuickFactsGrid(show: show),
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
                (g) => MediaHubMetaPill(
                  label: g,
                  color: AppColors.accentPrimary,
                ),
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

/// "Browse episodes" CTA card — sits in place of the old inline
/// Seasons & Episodes list. Tapping it opens the right-side
/// `MediaHubEpisodesDrawer`.
class _BrowseEpisodesCta extends StatelessWidget {
  const _BrowseEpisodesCta({
    required this.show,
    required this.seasons,
    required this.loadingTorrents,
    required this.onOpen,
  });

  final Show show;
  final AsyncValue<List<Season>> seasons;
  final bool loadingTorrents;
  final ValueChanged<List<Season>> onOpen;

  @override
  Widget build(BuildContext context) {
    final ready = seasons.maybeWhen(
      data: (s) => s.isNotEmpty,
      orElse: () => false,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () {
          if (!ready) return;
          final list = seasons.value!;
          onOpen(list);
        },
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.seedColor.withAlpha(36), AppColors.bgSurface],
            ),
            border: Border.all(color: AppColors.seedColor.withAlpha(0x40)),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.seedColor.withAlpha(50),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(
                  Icons.video_library_rounded,
                  color: AppColors.seedColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Browse episodes',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      seasons.maybeWhen(
                        data: (s) {
                          final n = s.where((x) => x.seasonNumber > 0).length;
                          return '$n ${n == 1 ? 'season' : 'seasons'} · '
                              '${show.numberOfEpisodes ?? 0} episodes · '
                              'pick one to grab';
                        },
                        loading: () => 'Loading seasons…',
                        orElse: () => 'Episode picker',
                      ),
                      style: AppType.mono(size: 12, color: AppColors.fg2),
                    ),
                  ],
                ),
              ),
              if (loadingTorrents)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.chevron_right_rounded, color: AppColors.fg1),
            ],
          ),
        ),
      ),
    );
  }
}

/// Generic titled section block used for Storyline / Quick facts /
/// other info groups on the show details page.
class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: AppType.mono(
            size: 11,
            color: AppColors.fg2,
            weight: FontWeight.w700,
            letterSpacing: 0.08,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        child,
      ],
    );
  }
}

/// Two-column quick-facts grid for the show details info section.
class _QuickFactsGrid extends StatelessWidget {
  const _QuickFactsGrid({required this.show});

  final Show show;

  @override
  Widget build(BuildContext context) {
    final facts = <(String, String)>[
      if (show.firstAirDate != null) ('First aired', show.firstAirDate!),
      if (show.lastAirDate != null && show.hasEnded)
        ('Last aired', show.lastAirDate!),
      if (show.statusLabel != null) ('Status', show.statusLabel!),
      if (show.numberOfSeasons != null) ('Seasons', '${show.numberOfSeasons}'),
      if (show.numberOfEpisodes != null)
        ('Episodes', '${show.numberOfEpisodes}'),
      if (show.episodeRunTime != null && show.episodeRunTime!.isNotEmpty)
        ('Runtime', '${show.episodeRunTime!.first} min'),
      if (show.genres.isNotEmpty) ('Genres', show.genres.take(3).join(', ')),
      if (show.voteAverage > 0)
        ('Rating', '${show.voteAverage.toStringAsFixed(1)} / 10'),
    ];

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          for (var i = 0; i < facts.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.line),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      facts[i].$1.toUpperCase(),
                      style: AppType.mono(
                        size: 11,
                        color: AppColors.fg2,
                        letterSpacing: 0.05,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      facts[i].$2,
                      style: const TextStyle(fontSize: 13, color: AppColors.fg),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
