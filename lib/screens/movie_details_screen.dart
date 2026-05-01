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
import '../widgets/mediahub_backdrop_hero.dart';
import '../widgets/mediahub_torrent_drawer.dart';
import '../widgets/movie_card.dart';
import '../widgets/streaming_progress_overlay.dart';
import 'settings_screen.dart';
import 'video_player_screen.dart';

/// Screen for displaying movie details
class MovieDetailsScreen extends ConsumerStatefulWidget {
  final Movie movie;

  const MovieDetailsScreen({super.key, required this.movie});

  @override
  ConsumerState<MovieDetailsScreen> createState() => _MovieDetailsScreenState();
}

class _MovieDetailsScreenState extends ConsumerState<MovieDetailsScreen> {
  bool _isLoadingStreams = false;
  bool _isStreaming = false;
  OverlayEntry? _streamingOverlay;
  ValueNotifier<StreamingOverlayData>? _streamingOverlayData;
  StreamSubscription<StreamingSession>? _monitorSubscription;

  @override
  void dispose() {
    _monitorSubscription?.cancel();
    _streamingOverlay?.remove();
    _streamingOverlayData?.dispose();
    super.dispose();
  }

  Future<void> _onDownloadTap(Movie movieDetails) async {
    if (movieDetails.imdbId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IMDB ID not available for this movie')),
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No streams available for this movie'),
            ),
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

  /// Start a streaming session with the floating progress overlay —
  /// mirrors the TV-show flow so movies get the same card-style feedback.
  Future<void> _startStreamingSession(
    TorrentioStream stream,
    Movie movie,
  ) async {
    final containerRef = ProviderScope.containerOf(context);

    _streamingOverlay?.remove();
    _streamingOverlayData?.dispose();

    final result = showUpdatableStreamingOverlay(
      context,
      title: 'Starting "${movie.title}"',
      subtitle: stream.isSingleFile
          ? 'Connecting...'
          : 'Selecting from pack...',
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

    setState(() => _isStreaming = true);
    final session = await ref
        .read(streamingSessionsProvider.notifier)
        .startStreaming(stream: stream, movieImdbId: movie.imdbId);

    if (session == null) {
      _streamingOverlay?.remove();
      _streamingOverlay = null;
      _streamingOverlayData?.dispose();
      _streamingOverlayData = null;
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

  /// Listen to session updates and drive the overlay/player navigation.
  void _monitorStreamingSession(String sessionId, Movie movie) {
    final streamingService = ref.read(streamingServiceProvider);
    final sessionStream = streamingService.getSessionStream(sessionId);
    if (sessionStream == null) return;

    _monitorSubscription?.cancel();
    _monitorSubscription = sessionStream.listen((session) {
      switch (session.state) {
        case StreamingState.buffering:
          _streamingOverlayData?.value = StreamingOverlayData(
            title: 'Buffering "${movie.title}"',
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
                ),
              ),
            );
          } else if (session.contentPath != null) {
            _openStreamingPlayer(session.contentPath!, movie);
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

    return Scaffold(
      body: movieDetails.when(
        data: (movie) => _buildContent(movie),
        loading: () => const Center(child: CircularProgressIndicator()),
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

    return CustomScrollView(
      slivers: [
        // Cinematic MediaHub backdrop hero — replaces the previous
        // SliverAppBar + duplicated poster/title row. Provides full-
        // bleed backdrop, big display title, mono metadata pills, and
        // the primary Get-torrent CTA.
        SliverToBoxAdapter(
          child: Stack(
            children: [
              MediaHubBackdropHero(
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
                      color: const Color(0xFFB4B4C8),
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
              // Floating back button — overlaid in the top-left of
              // the cinematic hero, glassmorphic styling.
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
                          return Material(
                            color: Colors.white.withAlpha(20),
                            shape: const CircleBorder(),
                            child: IconButton(
                              onPressed: () => ref
                                  .read(favoritesProvider.notifier)
                                  .toggleMovieFavorite(
                                    movie.id,
                                    movie: movie,
                                  ),
                              icon: Icon(
                                fav
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_outline_rounded,
                                color: fav
                                    ? Colors.redAccent
                                    : Colors.white,
                              ),
                              tooltip: fav
                                  ? 'Remove from favorites'
                                  : 'Add to favorites',
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Consumer(
                        builder: (context, ref, _) {
                          final wl = ref.watch(
                            isMovieOnWatchlistProvider(movie.id),
                          );
                          return Material(
                            color: Colors.white.withAlpha(20),
                            shape: const CircleBorder(),
                            child: IconButton(
                              onPressed: () => ref
                                  .read(watchlistProvider.notifier)
                                  .toggleMovie(movie.id),
                              icon: Icon(
                                wl
                                    ? Icons.bookmark_rounded
                                    : Icons.bookmark_outline_rounded,
                                color: wl
                                    ? Colors.amberAccent
                                    : Colors.white,
                              ),
                              tooltip: wl
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
                          icon: const Icon(
                            Icons.settings_outlined,
                            color: Colors.white,
                          ),
                          tooltip: 'Settings',
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SettingsScreen(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
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

                // Similar movies
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
                                    child: MovieCard(
                                      movie: similar,
                                      width: 140,
                                      height: 210,
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
                  error: (_, __) => const SizedBox.shrink(),
                ),

                SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
