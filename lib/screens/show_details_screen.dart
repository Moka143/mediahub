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
import '../providers/torrentio_provider.dart';
import '../providers/eztv_provider.dart';
import '../providers/streaming_provider.dart';
import '../services/streaming_service.dart';
import '../widgets/season_tile.dart';
import '../widgets/streaming_progress_overlay.dart';
import '../widgets/torrentio_stream_picker_dialog.dart';
import 'video_player_screen.dart';

/// Screen for displaying TV show details with seasons and episodes
class ShowDetailsScreen extends ConsumerStatefulWidget {
  final Show show;

  const ShowDetailsScreen({super.key, required this.show});

  @override
  ConsumerState<ShowDetailsScreen> createState() => _ShowDetailsScreenState();
}

class _ShowDetailsScreenState extends ConsumerState<ShowDetailsScreen> {
  Map<int, bool> _expandedSeasons = {};
  Map<int, List<Episode>> _loadedEpisodes = {};
  Map<String, bool>? _torrentAvailability;
  bool _isLoadingTorrents = false;
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
    final showDetails = await ref.read(showDetailsProvider(widget.show.id).future);
    if (showDetails.imdbId == null) return;

    setState(() => _isLoadingTorrents = true);

    try {
      final availability = await ref.read(
        checkTorrentAvailabilityProvider(showDetails.imdbId!).future,
      );
      if (mounted) {
        setState(() {
          _torrentAvailability = availability;
          _isLoadingTorrents = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingTorrents = false);
      }
    }
  }

  Future<void> _loadEpisodes(int seasonNumber) async {
    if (_loadedEpisodes.containsKey(seasonNumber)) return;

    try {
      final episodes = await ref.read(
        seasonEpisodesProvider((showId: widget.show.id, seasonNumber: seasonNumber)).future,
      );
      if (mounted) {
        setState(() {
          _loadedEpisodes[seasonNumber] = episodes;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load episodes: $e')),
        );
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
            const SnackBar(content: Text('No streams available for this episode')),
          );
        }
        return;
      }

      if (mounted) {
        await TorrentioStreamPickerDialog.show(
          context: context,
          title: showDetails.name,
          subtitle: episode.episodeCode,
          streams: response.streams,
          onSelect: (stream, isStreaming) => _downloadStream(stream, episode, showDetails, isStreaming: isStreaming),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load streams: $e')),
        );
      }
    }
  }

  Future<void> _downloadStream(TorrentioStream stream, Episode episode, Show show, {bool isStreaming = false}) async {
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
            content: Text('Started downloading ${episode.episodeCode}${stream.isSeasonPack ? " (from pack)" : ""}'),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'View Downloads',
              textColor: Colors.white,
              onPressed: () {
                messenger.hideCurrentSnackBar();
                containerRef.read(currentTabIndexProvider.notifier).set(0);
                rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
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
  Future<void> _startStreamingSession(TorrentioStream stream, Episode episode, Show show) async {
    final containerRef = ProviderScope.containerOf(context);
    
    // Show initial streaming overlay (updatable, so _monitorStreamingSession
    // can update it in-place without replaying the entrance animation).
    final isSingleFile = stream.isSingleFile;
    _streamingOverlay?.remove();
    _streamingOverlayData?.dispose();

    final result = showUpdatableStreamingOverlay(
      context,
      title: 'Starting ${episode.episodeCode}',
      subtitle: isSingleFile ? 'Connecting...' : 'Selecting from season pack...',
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
    final session = await ref.read(streamingSessionsProvider.notifier).startStreaming(
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
          debugPrint('[ShowDetails] No files found in torrent, cannot select specific file');
          return;
        }
      }
      
      // Set all files to skip (priority 0)
      final allFileIds = List.generate(files.length, (i) => i);
      await apiService.setFilePriority(stream.infoHash, allFileIds, 0);
      
      // Set target file to high priority
      if (stream.fileIdx! < files.length) {
        await apiService.setFilePriority(stream.infoHash, [stream.fileIdx!], 7);
        debugPrint('[ShowDetails] Selected file ${stream.fileIdx} from season pack');
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
            subtitle: '${(session.bufferProgress * 100).toStringAsFixed(1)}% ready',
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
          containerRef.read(streamingSessionsProvider.notifier).clearActiveSession();

          // Navigate via root key — works whether screen is mounted or not
          if (session.videoFile != null) {
            rootNavigatorKey.currentState?.push(
              MaterialPageRoute(
                builder: (_) => VideoPlayerScreen(
                  file: session.videoFile!,
                  showImdbId: show.imdbId,
                  isStreaming: true,
                ),
              ),
            );
          } else if (session.contentPath != null && session.selectedFilePath != null) {
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
              content: Text('Streaming error: ${session.errorMessage ?? "Failed to stream"}'),
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
        builder: (_) => VideoPlayerScreen(
          file: file,
          showImdbId: show.imdbId,
        ),
      ),
    );
  }

  Future<void> _monitorStreamingProgress(TorrentioStream stream, Episode episode, Show show) async {
    final apiService = ref.read(connection_provider.qbApiServiceProvider);
    final messenger = rootScaffoldMessengerKey.currentState;
    
    // Poll for torrent progress
    for (int i = 0; i < 120; i++) { // Max 10 minutes (120 * 5s)
      await Future.delayed(const Duration(seconds: 5));
      
      if (!mounted) return;
      
      // Find the torrent by matching the magnet hash
      final torrents = await apiService.getTorrents();
      final torrent = torrents.firstWhereOrNull((t) => 
        stream.magnetUri.toLowerCase().contains(t.hash.toLowerCase())
      );
      
      if (torrent == null) continue;
      
      // Check if ready for streaming (at least 5% of beginning downloaded)
      final isReady = await apiService.isReadyForStreaming(torrent.hash, minProgress: 0.05);
      
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
            content: Text('Buffering ${episode.episodeCode}... ${(torrent.progress * 100).toStringAsFixed(1)}%'),
            backgroundColor: AppColors.info,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
    
    // Timeout
    messenger?.showSnackBar(
      SnackBar(
        content: Text('Streaming timeout for ${episode.episodeCode}. Download continues in background.'),
        backgroundColor: AppColors.warning,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _openStreamingPlayer(String contentPath, Episode episode, Show show) async {
    // Find the video file in the content path
    final videoFile = await _findVideoFile(contentPath, episode: episode, show: show);
    
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
          builder: (context) => VideoPlayerScreen(
            file: videoFile,
            showImdbId: show.imdbId,
          ),
        ),
      );
    }
  }

  Future<LocalMediaFile?> _findVideoFile(String contentPath, {Episode? episode, Show? show}) async {
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
    return CustomScrollView(
      slivers: [
        // App bar with backdrop
        _buildSliverAppBar(show, isFavorite),

        // Show info
        SliverToBoxAdapter(
          child: _buildShowInfo(show),
        ),

        // Seasons
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.video_library_rounded,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  'Seasons & Episodes',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                if (_isLoadingTorrents) ...[
                  const SizedBox(width: AppSpacing.md),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Season list
        seasons.when(
          data: (seasonList) => SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final season = seasonList[index];
                final isExpanded = _expandedSeasons[season.seasonNumber] ?? false;
                final episodes = _loadedEpisodes[season.seasonNumber] ?? [];

                return SeasonTile(
                  season: season,
                  episodes: episodes,
                  isExpanded: isExpanded,
                  isLoading: isExpanded && episodes.isEmpty,
                  showName: show.name,
                  isStreaming: _isStreaming,
                  torrentAvailability: _torrentAvailability,
                  onExpansionChanged: (expanded) {
                    setState(() {
                      _expandedSeasons[season.seasonNumber] = expanded;
                    });
                    if (expanded) {
                      _loadEpisodes(season.seasonNumber);
                    }
                  },
                  onEpisodeTap: (episode) => _onEpisodeTap(episode, show),
                  onDownloadTap: (episode) => _onEpisodeTap(episode, show),
                );
              },
              childCount: seasonList.length,
            ),
          ),
          loading: () => SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: const CircularProgressIndicator(),
              ),
            ),
          ),
          error: (error, _) => SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Text('Error loading seasons: $error'),
              ),
            ),
          ),
        ),

        // Bottom padding
        SliverToBoxAdapter(
          child: SizedBox(height: AppSpacing.xl),
        ),
      ],
    );
  }

  Widget _buildSliverAppBar(Show show, bool isFavorite) {
    return SliverAppBar(
      expandedHeight: 250,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            // Backdrop image
            if (show.backdropUrl != null)
              Image.network(
                show.backdropUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              )
            else
              Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),

            // Gradient overlay
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.8),
                  ],
                ),
              ),
            ),

            // Show title at bottom
            Positioned(
              bottom: 16,
              left: 16,
              right: 60,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    show.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                    ),
                  ),
                  if (show.year != null || show.status != null)
                    Text(
                      [
                        if (show.year != null) show.year,
                        if (show.status != null) show.status,
                      ].join(' • '),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 14,
                        shadows: const [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // Favorite button
        Container(
          margin: const EdgeInsets.only(right: AppSpacing.sm),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(AppOpacity.medium),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            onPressed: () {
              ref.read(favoritesProvider.notifier).toggleFavorite(show.id, show: show);
            },
            icon: Icon(
              isFavorite ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
              color: isFavorite ? Colors.redAccent : Colors.white,
            ),
            tooltip: isFavorite ? 'Remove from favorites' : 'Add to favorites',
          ),
        ),
      ],
    );
  }

  Widget _buildShowInfo(Show show) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Rating and info row
          Row(
            children: [
              // Rating
              if (show.voteAverage > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: getRatingColor(show.voteAverage).withAlpha(AppOpacity.light),
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.star_rounded,
                        size: AppIconSize.sm,
                        color: getRatingColor(show.voteAverage),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        show.voteAverage.toStringAsFixed(1),
                        style: TextStyle(
                          color: getRatingColor(show.voteAverage),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(width: AppSpacing.md),

              // Seasons count
              if (show.numberOfSeasons != null)
                Text(
                  '${show.numberOfSeasons} Seasons',
                  style: TextStyle(color: appColors.mutedText),
                ),

              const SizedBox(width: AppSpacing.md),

              // Episodes count
              if (show.numberOfEpisodes != null)
                Text(
                  '${show.numberOfEpisodes} Episodes',
                  style: TextStyle(color: appColors.mutedText),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // Genres
          if (show.genres.isNotEmpty)
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: show.genres
                  .map((genre) => Chip(
                        label: Text(genre),
                        labelStyle: const TextStyle(fontSize: 12),
                        padding: EdgeInsets.zero,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ))
                  .toList(),
            ),
          SizedBox(height: AppSpacing.lg),

          // Overview
          if (show.overview != null && show.overview!.isNotEmpty)
            Text(
              show.overview!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: appColors.subtleText,
                height: 1.5,
              ),
            ),

          // Next episode info
          if (show.nextEpisodeToAir != null) ...[
            SizedBox(height: AppSpacing.lg),
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
                    child: Icon(Icons.schedule_rounded, color: appColors.warning, size: 20),
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
