import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../design/app_colors.dart';
import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../models/show.dart';
import '../models/season.dart';
import '../models/episode.dart';
import '../models/torrentio_stream.dart';
import '../providers/connection_provider.dart' as connection_provider;
import '../providers/navigation_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/watchlist_provider.dart';
import '../providers/torrentio_provider.dart';
import '../providers/eztv_provider.dart';
import '../providers/streaming_provider.dart';
import '../services/streaming_service.dart';
import '../widgets/mediahub_backdrop_hero.dart';
import '../widgets/mediahub_episodes_drawer.dart';
import '../widgets/mediahub_torrent_drawer.dart';
import '../widgets/streaming_progress_overlay.dart';
import 'settings_screen.dart';
import 'video_player_screen.dart';

/// Screen for displaying TV show details with seasons and episodes
class ShowDetailsScreen extends ConsumerStatefulWidget {
  final Show show;

  const ShowDetailsScreen({super.key, required this.show});

  @override
  ConsumerState<ShowDetailsScreen> createState() => _ShowDetailsScreenState();
}

class _ShowDetailsScreenState extends ConsumerState<ShowDetailsScreen> {
  // Episodes are fetched on-demand by the drawer; we keep a small
  // cache here for streaming-flow continuity.
  final Map<int, List<Episode>> _loadedEpisodes = {};
  bool _isLoadingTorrents = false;
  // Whether a streaming session is currently active — referenced by
  // the streaming-progress overlay that can outlive this screen.
  // ignore: unused_field
  bool _isStreaming = false;
  OverlayEntry? _streamingOverlay;
  ValueNotifier<StreamingOverlayData>? _streamingOverlayData;
  // Subscription survives the screen being popped — uses root keys for navigation
  StreamSubscription<StreamingSession>? _monitorSubscription;

  @override
  void initState() {
    super.initState();
    _loadTorrentAvailability();
  }

  @override
  void dispose() {
    _monitorSubscription?.cancel();
    _streamingOverlay?.remove();
    _streamingOverlayData?.dispose();
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

  Future<void> _loadEpisodes(int seasonNumber) async {
    if (_loadedEpisodes.containsKey(seasonNumber)) return;

    try {
      final episodes = await ref.read(
        seasonEpisodesProvider((
          showId: widget.show.id,
          seasonNumber: seasonNumber,
        )).future,
      );
      if (mounted) {
        setState(() {
          _loadedEpisodes[seasonNumber] = episodes;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load episodes: $e')));
      }
    }
  }

  Future<void> _onEpisodeTap(Episode episode, Show showDetails) async {
    if (showDetails.imdbId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IMDB ID not available for this show')),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No streams available for this episode'),
            ),
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
        // Use the new streaming service for robust streaming
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
                containerRef.read(currentTabIndexProvider.notifier).set(0);
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
    _streamingOverlay?.remove();
    _streamingOverlayData?.dispose();

    final result = showUpdatableStreamingOverlay(
      context,
      title: 'Starting ${episode.episodeCode}',
      subtitle: isSingleFile
          ? 'Connecting...'
          : 'Selecting from season pack...',
      isIndeterminate: true,
      showClose: true,
      onClose: () {
        _streamingOverlay = null;
        _streamingOverlayData = null;
      },
      onViewDownloads: () {
        _streamingOverlay?.remove();
        _streamingOverlay = null;
        _streamingOverlayData?.dispose();
        _streamingOverlayData = null;
        containerRef.read(currentTabIndexProvider.notifier).set(0);
        rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
      },
    );
    _streamingOverlay = result.entry;
    _streamingOverlayData = result.data;

    // Start streaming session
    setState(() => _isStreaming = true);
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
      _streamingOverlay?.remove();
      _streamingOverlay = null;

      ScaffoldMessenger.of(context).showSnackBar(
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
    final streamingService = ref.read(streamingServiceProvider);
    final containerRef = ProviderScope.containerOf(context);

    // Reuse the overlay created by _startStreamingSession if it's already up;
    // otherwise create one (e.g. when called from a different entry point).
    if (mounted && _streamingOverlayData != null) {
      _streamingOverlayData!.value = StreamingOverlayData(
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
          _streamingOverlay = null;
          _streamingOverlayData = null;
        },
        onViewDownloads: () {
          _streamingOverlay?.remove();
          _streamingOverlay = null;
          _streamingOverlayData?.dispose();
          _streamingOverlayData = null;
          containerRef.read(currentTabIndexProvider.notifier).set(0);
          rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        },
      );
      _streamingOverlay = result.entry;
      _streamingOverlayData = result.data;
    }

    final sessionStream = streamingService.getSessionStream(sessionId);
    if (sessionStream == null) return;

    _monitorSubscription?.cancel();
    _monitorSubscription = sessionStream.listen((session) {
      switch (session.state) {
        case StreamingState.buffering:
          // Update the existing overlay in-place — no remove/recreate, no flicker.
          _streamingOverlayData?.value = StreamingOverlayData(
            title: 'Buffering ${episode.episodeCode}',
            subtitle:
                '${(session.bufferProgress * 100).toStringAsFixed(1)}% ready',
            progress: session.bufferProgress,
            isIndeterminate: false,
          );

        case StreamingState.ready:
          _monitorSubscription?.cancel();
          _streamingOverlay?.remove();
          _streamingOverlay = null;
          _streamingOverlayData?.dispose();
          _streamingOverlayData = null;
          if (mounted) setState(() => _isStreaming = false);

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
          _monitorSubscription?.cancel();
          _streamingOverlay?.remove();
          _streamingOverlay = null;
          _streamingOverlayData?.dispose();
          _streamingOverlayData = null;
          if (mounted) setState(() => _isStreaming = false);

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
          _monitorSubscription?.cancel();
          _streamingOverlay?.remove();
          _streamingOverlay = null;
          _streamingOverlayData?.dispose();
          _streamingOverlayData = null;
          if (mounted) setState(() => _isStreaming = false);

        default:
          break;
      }
    });
  }

  /// Open the video player with a LocalMediaFile.
  /// Uses [rootNavigatorKey] so it works even if this screen is no longer mounted.
  void _openPlayerWithFile(LocalMediaFile file, Show show) {
    _streamingOverlay?.remove();
    _streamingOverlay = null;

    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(file: file, showImdbId: show.imdbId),
      ),
    );
  }

  Future<void> _monitorStreamingProgress(
    TorrentioStream stream,
    Episode episode,
    Show show,
  ) async {
    final apiService = ref.read(connection_provider.qbApiServiceProvider);
    final messenger = rootScaffoldMessengerKey.currentState;

    // Poll for torrent progress
    for (int i = 0; i < 120; i++) {
      // Max 10 minutes (120 * 5s)
      await Future.delayed(const Duration(seconds: 5));

      if (!mounted) return;

      // Find the torrent by matching the magnet hash
      final torrents = await apiService.getTorrents();
      final torrent = torrents.firstWhereOrNull(
        (t) => stream.magnetUri.toLowerCase().contains(t.hash.toLowerCase()),
      );

      if (torrent == null) continue;

      // Check if ready for streaming (at least 5% of beginning downloaded)
      final isReady = await apiService.isReadyForStreaming(
        torrent.hash,
        minProgress: 0.05,
      );

      if (isReady) {
        if (mounted) {
          messenger?.hideCurrentSnackBar();
          messenger?.showSnackBar(
            SnackBar(
              content: Text('Stream ready! Opening ${episode.episodeCode}...'),
              backgroundColor: AppColors.success,
              duration: const Duration(seconds: 3),
            ),
          );

          // Navigate to player with the content path
          _openStreamingPlayer(torrent.contentPath, episode, show);
        }
        return;
      }

      // Update progress message every 30 seconds
      if (i % 6 == 0 && i > 0) {
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              'Buffering ${episode.episodeCode}... ${(torrent.progress * 100).toStringAsFixed(1)}%',
            ),
            backgroundColor: AppColors.info,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }

    // Timeout
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Streaming timeout for ${episode.episodeCode}. Download continues in background.',
        ),
        backgroundColor: AppColors.warning,
        duration: const Duration(seconds: 5),
      ),
    );
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

    return Scaffold(
      body: showDetails.when(
        data: (show) => _buildContent(show, seasons, isFavorite),
        loading: () => const Center(child: CircularProgressIndicator()),
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

    return CustomScrollView(
      slivers: [
        // Cinematic backdrop hero — left full-bleed.
        _buildSliverAppBar(show, isFavorite),

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
                                color: Color(0xFFB4B4C8),
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
    );
  }

  Widget _buildSliverAppBar(Show show, bool isFavorite) {
    // Cinematic MediaHub backdrop hero — full-bleed image, big
    // display title, mono metadata pills, overlaid back/favorite
    // controls. Replaces the old SliverAppBar.
    return SliverToBoxAdapter(
      child: Stack(
        children: [
          MediaHubBackdropHero(
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
                  color: AppColors.accentTertiary,
                ),
              if (show.numberOfSeasons != null)
                MediaHubMetaPill(
                  label:
                      '${show.numberOfSeasons} ${show.numberOfSeasons == 1 ? "SEASON" : "SEASONS"}',
                  color: const Color(0xFFB4B4C8),
                ),
              if (show.numberOfEpisodes != null)
                MediaHubMetaPill(
                  label: '${show.numberOfEpisodes} EP',
                  color: const Color(0xFFB4B4C8),
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
              onPressed: () {
                // Scroll down to the seasons list — user can pick an
                // episode there. Quick CTA from the hero.
                Scrollable.ensureVisible(context, duration: AppDuration.normal);
              },
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
          // Floating top controls — back + favorite
          Positioned(
            top: AppSpacing.lg,
            left: AppSpacing.xxl,
            child: SafeArea(
              child: Material(
                color: Colors.white.withAlpha(20),
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).pop(),
                ),
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
                  Material(
                    color: Colors.white.withAlpha(20),
                    shape: const CircleBorder(),
                    child: IconButton(
                      onPressed: () {
                        ref
                            .read(favoritesProvider.notifier)
                            .toggleFavorite(show.id, show: show);
                      },
                      icon: Icon(
                        isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_outline_rounded,
                        color: isFavorite ? Colors.redAccent : Colors.white,
                      ),
                      tooltip: isFavorite
                          ? 'Remove from favorites'
                          : 'Add to favorites',
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Consumer(
                    builder: (context, ref, _) {
                      final onWatchlist =
                          ref.watch(isOnWatchlistProvider(show.id));
                      return Material(
                        color: Colors.white.withAlpha(20),
                        shape: const CircleBorder(),
                        child: IconButton(
                          onPressed: () => ref
                              .read(watchlistProvider.notifier)
                              .toggleShow(show.id),
                          icon: Icon(
                            onWatchlist
                                ? Icons.bookmark_rounded
                                : Icons.bookmark_outline_rounded,
                            color: onWatchlist
                                ? Colors.amberAccent
                                : Colors.white,
                          ),
                          tooltip: onWatchlist
                              ? 'Remove from watchlist'
                              : 'Add to watchlist',
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Material(
                    color: Colors.white.withAlpha(20),
                    shape: const CircleBorder(),
                    child: IconButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      ),
                      icon: const Icon(
                        Icons.settings_outlined,
                        color: Colors.white,
                      ),
                      tooltip: 'Settings',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShowInfo(Show show) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    // The MediaHub hero already presents rating / seasons / episodes /
    // genres / overview, so this section just shows the upcoming
    // episode card when available.
    if (show.nextEpisodeToAir == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        AppSpacing.lg,
        AppSpacing.screenPadding,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Next episode info
          if (show.nextEpisodeToAir != null) ...[
            Container(
              padding: EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    appColors.warningBackground,
                    appColors.warningBackground.withAlpha(AppOpacity.medium),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: appColors.warning.withAlpha(AppOpacity.light),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: appColors.warning.withAlpha(AppOpacity.light),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(
                      Icons.schedule_rounded,
                      color: appColors.warning,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Upcoming Episode',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: appColors.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        show.nextEpisodeToAir!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: appColors.warning,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
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
                        color: Color(0xFFF4F4F8),
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF7A7A92),
                        fontFamily: 'monospace',
                      ),
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
                const Icon(
                  Icons.chevron_right_rounded,
                  color: Color(0xFFB4B4C8),
                ),
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
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF7A7A92),
            letterSpacing: 0.88,
            fontFamily: 'monospace',
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
        border: Border.all(color: const Color(0x0FFFFFFF)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          for (var i = 0; i < facts.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: Color(0x0FFFFFFF)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      facts[i].$1.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Color(0xFF7A7A92),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      facts[i].$2,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFFF4F4F8),
                      ),
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
