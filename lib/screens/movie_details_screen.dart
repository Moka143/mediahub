import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../models/movie.dart';
import '../models/torrentio_stream.dart';
import '../providers/connection_provider.dart' as connection_provider;
import '../providers/favorites_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/movies_provider.dart';
import '../providers/watchlist_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/torrentio_provider.dart';
import '../services/streaming_service.dart';
import '../utils/feedback_utils.dart';
import '../utils/formatters.dart';
import '../widgets/common/floating_header_action.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/media/cast_row.dart';
import '../widgets/media/trailers_row.dart';
import '../widgets/mediahub_backdrop_hero.dart';
import '_details_playback_controller.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/mediahub_torrent_drawer.dart';
import '../widgets/streaming_progress_overlay.dart';
import 'settings_screen.dart';
import 'video_player_screen.dart';

/// Screen for displaying movie details
class MovieDetailsScreen extends ConsumerStatefulWidget {
  final Movie movie;

  /// When true, the torrent picker fires automatically as soon as the
  /// full movie record (with imdbId) resolves. Used by the browse
  /// spotlight's "Get torrent" CTA.
  final bool autoOpenTorrentPicker;

  const MovieDetailsScreen({
    super.key,
    required this.movie,
    this.autoOpenTorrentPicker = false,
  });

  @override
  ConsumerState<MovieDetailsScreen> createState() => _MovieDetailsScreenState();
}

class _MovieDetailsScreenState extends ConsumerState<MovieDetailsScreen>
    with DetailsPlaybackController<MovieDetailsScreen> {
  bool _isLoadingStreams = false;
  bool _isStreaming = false;
  bool _autoPickerFired = false;
  // Streaming overlay + subscription lifecycle (streamingOverlay,
  // streamingOverlayData, monitorSubscription) lives on
  // DetailsPlaybackController; tear down via disposePlaybackController().

  @override
  void dispose() {
    disposePlaybackController();
    super.dispose();
  }

  Future<void> _onDownloadTap(Movie movieDetails) async {
    if (movieDetails.imdbId == null) {
      AppSnackBar.showError(
        context,
        message: 'IMDB ID not available for this movie',
      );
      return;
    }

    setState(() => _isLoadingStreams = true);

    try {
      final response = await ref.read(
        movieStreamsProvider(movieDetails.imdbId!).future,
      );

      if (response.streams.isEmpty) {
        if (mounted) {
          AppSnackBar.showInfo(
            context,
            message: 'No streams available for this movie',
          );
        }
        return;
      }

      if (mounted) {
        await MediaHubTorrentDrawer.show(
          context: context,
          title: movieDetails.title,
          subtitle: movieDetails.year,
          streams: response.streams,
          onSelect: (stream, isStreaming) =>
              _downloadStream(stream, movieDetails, isStreaming: isStreaming),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load streams: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingStreams = false);
      }
    }
  }

  Future<void> _downloadStream(
    TorrentioStream stream,
    Movie movie, {
    bool isStreaming = false,
  }) async {
    final connectionState = ref.read(connection_provider.connectionProvider);

    // Use the global ScaffoldMessenger
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
        // Local-first: skip the streaming dance entirely if the movie is
        // already on disk. qBit doesn't always know about a previously-
        // downloaded file that was removed from its session, so re-adding
        // the magnet would either start a fresh download or a full
        // re-hash-check — and the "Preparing" modal would hang waiting
        // for the buffer threshold either way.
        final localFile = ref.read(movieLocalFileProvider(movie.title));
        if (localFile != null && File(localFile.path).existsSync()) {
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) =>
                  VideoPlayerScreen(file: localFile, movieImdbId: movie.imdbId),
            ),
          );
          return;
        }

        await _startStreamingSession(stream, movie);
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
        messenger.showSnackBar(
          SnackBar(
            content: Text('Started downloading "${movie.title}"'),
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

  /// Start a streaming session with the floating progress overlay —
  /// mirrors the TV-show flow so movies get the same card-style feedback.
  Future<void> _startStreamingSession(
    TorrentioStream stream,
    Movie movie,
  ) async {
    final containerRef = ProviderScope.containerOf(context);

    streamingOverlay?.remove();
    streamingOverlayData?.dispose();

    final result = showUpdatableStreamingOverlay(
      context,
      title: 'Starting "${movie.title}"',
      subtitle: stream.isSingleFile
          ? 'Connecting...'
          : 'Selecting from pack...',
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

    setState(() => _isStreaming = true);
    final session = await ref
        .read(streamingSessionsProvider.notifier)
        .startStreaming(stream: stream, movieImdbId: movie.imdbId);

    if (session == null) {
      streamingOverlay?.remove();
      streamingOverlay = null;
      streamingOverlayData?.dispose();
      streamingOverlayData = null;
      if (mounted) setState(() => _isStreaming = false);
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Failed to start streaming session'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    _monitorStreamingSession(session.id, movie);
  }

  /// Listen to session updates via the Riverpod notifier (NOT the streaming
  /// service's broadcast stream — that has a race where early state
  /// transitions can fire before the UI subscribes).
  ///
  /// `fireImmediately: true` makes the listener tick once with the current
  /// state on registration, so if the session has already advanced
  /// (e.g. fast-path to ready), we react right away.
  void _monitorStreamingSession(String sessionId, Movie movie) {
    monitorSubscription?.close();
    monitorSubscription = ref.listenManual<StreamingSessionsState>(
      streamingSessionsProvider,
      (prev, next) {
        final session = next.sessions[sessionId];
        if (session == null) return;
        _handleSessionState(session, movie);
      },
      fireImmediately: true,
    );
  }

  void _handleSessionState(StreamingSession session, Movie movie) {
    switch (session.state) {
      case StreamingState.addingTorrent:
      case StreamingState.selectingFiles:
      case StreamingState.buffering:
        final pct = session.bufferProgress * 100;
        final titlePrefix = session.state == StreamingState.buffering
            ? 'Buffering'
            : 'Preparing';
        final speed = session.downloadRateBytesPerSec;
        final speedSuffix = speed > 0
            ? ' • ${Formatters.formatSpeed(speed)}'
            : '';
        streamingOverlayData?.value = StreamingOverlayData(
          title: '$titlePrefix "${movie.title}"',
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
        if (mounted) setState(() => _isStreaming = false);

        ref.read(streamingSessionsProvider.notifier).clearActiveSession();

        if (session.videoFile != null) {
          rootNavigatorKey.currentState?.push(
            MaterialPageRoute(
              builder: (_) => VideoPlayerScreen(
                file: session.videoFile!,
                movieImdbId: movie.imdbId,
                isStreaming: true,
                streamingTorrentHash: session.torrentHash,
                streamingFileIndex: session.selectedFileIndex,
                streamingProxyUrl: session.streamUrl,
                initialBufferedRatio: session.bufferProgress,
              ),
            ),
          );
        } else if (session.contentPath != null) {
          _openStreamingPlayer(session.contentPath!, movie);
        }

      case StreamingState.error:
        monitorSubscription?.close();
        streamingOverlay?.remove();
        streamingOverlay = null;
        streamingOverlayData?.dispose();
        streamingOverlayData = null;
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
        monitorSubscription?.close();
        streamingOverlay?.remove();
        streamingOverlay = null;
        streamingOverlayData?.dispose();
        streamingOverlayData = null;
        if (mounted) setState(() => _isStreaming = false);

      case StreamingState.idle:
        break;
    }
  }

  void _openStreamingPlayer(String contentPath, Movie movie) async {
    final videoFile = await _findVideoFile(contentPath);

    if (videoFile == null) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text('Could not find video file in: $contentPath'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    // Use rootNavigatorKey — works whether the screen is mounted or not
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) =>
            VideoPlayerScreen(file: videoFile, movieImdbId: movie.imdbId),
      ),
    );
  }

  Future<LocalMediaFile?> _findVideoFile(String contentPath) async {
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
      );
    } catch (e) {
      debugPrint('Error finding video file: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final movieDetails = ref.watch(movieDetailsProvider(widget.movie.id));
    final theme = Theme.of(context);

    // When opened from the browse spotlight, fire the torrent picker
    // automatically as soon as the full movie record (with imdbId) lands.
    if (widget.autoOpenTorrentPicker && !_autoPickerFired) {
      movieDetails.whenData((m) {
        if (_autoPickerFired) return;
        _autoPickerFired = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _onDownloadTap(m);
        });
      });
    }

    return Scaffold(
      body: movieDetails.when(
        data: (movie) => _buildContent(movie),
        loading: () => const LoadingIndicator(),
        error: (error, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: theme.colorScheme.error,
              ),
              SizedBox(height: AppSpacing.md),
              Text('Failed to load movie details'),
              SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: () =>
                    ref.invalidate(movieDetailsProvider(widget.movie.id)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(Movie movie) {
    final theme = Theme.of(context);
    final similarMovies = ref.watch(similarMoviesProvider(movie.id));
    // Don't show as "in library" while actively streaming
    final localFile = _isStreaming
        ? null
        : ref.watch(movieLocalFileProvider(movie.title));

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            // Cinematic MediaHub backdrop hero — replaces the previous
            // SliverAppBar + duplicated poster/title row. Provides full-
            // bleed backdrop, big display title, mono metadata pills, and
            // the primary Get-torrent CTA.
            SliverToBoxAdapter(
              child: MediaHubBackdropHero(
                title: movie.title,
                year: movie.year,
                posterUrl: movie.posterUrl,
                backdropUrl: movie.backdropUrl,
                fallbackHue: (movie.id * 53 % 360).toDouble(),
                description:
                    (movie.tagline != null && movie.tagline!.isNotEmpty)
                    ? movie.tagline
                    : movie.overview,
                metaPills: [
                  if (movie.runtimeFormatted != null)
                    MediaHubMetaPill(
                      label: movie.runtimeFormatted!,
                      color: AppColors.fg1,
                    ),
                  if (movie.voteAverage > 0)
                    MediaHubMetaPill(
                      label: '★ ${movie.voteAverage.toStringAsFixed(1)}',
                      color: getRatingColor(movie.voteAverage),
                    ),
                  ...movie.genres
                      .take(3)
                      .map(
                        (g) => MediaHubMetaPill(
                          label: g,
                          color: AppColors.accentPrimary,
                        ),
                      ),
                ],
                primaryAction: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (localFile != null) ...[
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => VideoPlayerScreen(
                                file: localFile,
                                movieImdbId: movie.imdbId,
                                startPosition: localFile.hasProgress
                                    ? localFile.progress?.position
                                    : null,
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(
                          localFile.hasProgress && !localFile.isWatched
                              ? 'Continue'
                              : 'Resume',
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl,
                            vertical: AppSpacing.md,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    FilledButton.icon(
                      onPressed: _isLoadingStreams
                          ? null
                          : () => _onDownloadTap(movie),
                      icon: _isLoadingStreams
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.download_rounded, size: 16),
                      label: Text(_isLoadingStreams ? 'Loading…' : 'Get'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.seedColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xl,
                          vertical: AppSpacing.md,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Movie info — content below the cinematic hero
            SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.screenPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // (Hero already provides Resume/Get primary actions.)
                SizedBox(height: AppSpacing.lg),

                // Overview
                if (movie.overview != null && movie.overview!.isNotEmpty) ...[
                  Text(
                    'Overview',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: AppSpacing.sm),
                  Text(
                    movie.overview!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: AppSpacing.xl),
                ],
              ],
            ),
          ),
        ),

        // Trailers + Cast — separate slivers so the horizontal scrollers
        // can extend edge-to-edge instead of being inset by the
        // screen-padding wrapper above.
        if (movie.videos.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
              child: TrailersRow(videos: movie.videos),
            ),
          ),
        if (movie.cast.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
              child: CastRow(cast: movie.cast),
            ),
          ),

        // Similar movies — back inside its own padded sliver.
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // (Hero already provides Resume/Get primary actions.)
                similarMovies.when(
                  data: (movies) => movies.isNotEmpty
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Similar Movies',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: AppSpacing.md),
                            SizedBox(
                              height: 210,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                itemCount: movies.length,
                                itemBuilder: (context, index) {
                                  final similar = movies[index];
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      right: AppSpacing.md,
                                    ),
                                    child: MediaPosterCard(
                                      title: similar.title,
                                      width: 140,
                                      posterAsync: AsyncValue.data(
                                        similar.posterUrl,
                                      ),
                                      titleStyle: CardTitleStyle.overlay,
                                      overlayYear: similar.year,
                                      overlayRating: similar.voteAverage > 0
                                          ? '★ ${similar.voteAverage.toStringAsFixed(1)}'
                                          : null,
                                      overlayRatingTone:
                                          similar.voteAverage >= 8
                                          ? AppColors.accent
                                          : null,
                                      onTap: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (context) =>
                                                MovieDetailsScreen(
                                                  movie: similar,
                                                ),
                                          ),
                                        );
                                      },
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),

                SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
          ],
        ),
        // Floating back button — overlaid in the top-left.
        // Stays pinned regardless of scroll position.
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
        // Floating top-right actions: favorite, watchlist, settings.
        Positioned(
          top: AppSpacing.lg,
          right: AppSpacing.xxl,
          child: SafeArea(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    final fav = ref.watch(
                      isMovieFavoriteProvider(movie.id),
                    );
                    return FloatingHeaderAction(
                      icon: fav
                          ? Icons.favorite_rounded
                          : Icons.favorite_outline_rounded,
                      iconColor: fav ? Colors.redAccent : Colors.white,
                      tooltip: fav
                          ? 'Remove from favorites'
                          : 'Add to favorites',
                      onPressed: () => ref
                          .read(favoritesProvider.notifier)
                          .toggleMovieFavorite(movie.id, movie: movie),
                    );
                  },
                ),
                const SizedBox(width: AppSpacing.xs),
                Consumer(
                  builder: (context, ref, _) {
                    final wl = ref.watch(
                      isMovieOnWatchlistProvider(movie.id),
                    );
                    return FloatingHeaderAction(
                      icon: wl
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_outline_rounded,
                      iconColor: wl ? Colors.amberAccent : Colors.white,
                      tooltip: wl
                          ? 'Remove from watchlist'
                          : 'Add to watchlist',
                      onPressed: () => ref
                          .read(watchlistProvider.notifier)
                          .toggleMovie(movie.id),
                    );
                  },
                ),
                const SizedBox(width: AppSpacing.xs),
                FloatingHeaderAction(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsScreen(),
                    ),
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
