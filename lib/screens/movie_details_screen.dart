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
import '../providers/local_media_provider.dart';
import '../providers/movies_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/torrentio_provider.dart';
import '../services/streaming_service.dart';
import '../widgets/movie_card.dart';
import '../widgets/streaming_progress_overlay.dart';
import '../widgets/torrentio_stream_picker_dialog.dart';
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
        await TorrentioStreamPickerDialog.show(
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
        // Backdrop header
        SliverAppBar(
          expandedHeight: 300,
          pinned: true,
          stretch: true,
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                // Backdrop image
                if (movie.backdropUrl != null)
                  Image.network(
                    movie.backdropUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                  )
                else
                  Container(color: theme.colorScheme.surfaceContainerHighest),

                // Gradient overlay
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withAlpha(AppOpacity.strong),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Movie info
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.screenPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title and year
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Poster
                    if (movie.posterUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        child: Image.network(
                          movie.posterUrl!,
                          width: 120,
                          height: 180,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 120,
                            height: 180,
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: Icon(
                              Icons.movie_outlined,
                              size: 48,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    SizedBox(width: AppSpacing.lg),

                    // Title and metadata
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            movie.title,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (movie.tagline != null &&
                              movie.tagline!.isNotEmpty) ...[
                            SizedBox(height: AppSpacing.xs),
                            Text(
                              movie.tagline!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                          SizedBox(height: AppSpacing.md),

                          // Metadata row
                          Wrap(
                            spacing: AppSpacing.md,
                            runSpacing: AppSpacing.sm,
                            children: [
                              if (movie.year != null)
                                _MetadataChip(
                                  icon: Icons.calendar_today_rounded,
                                  label: movie.year!,
                                ),
                              if (movie.runtimeFormatted != null)
                                _MetadataChip(
                                  icon: Icons.access_time_rounded,
                                  label: movie.runtimeFormatted!,
                                ),
                              if (movie.voteAverage > 0)
                                _MetadataChip(
                                  icon: Icons.star_rounded,
                                  label: movie.voteAverage.toStringAsFixed(1),
                                  iconColor: getRatingColor(movie.voteAverage),
                                ),
                            ],
                          ),
                          SizedBox(height: AppSpacing.sm),

                          // Genres
                          if (movie.genres.isNotEmpty)
                            Wrap(
                              spacing: AppSpacing.xs,
                              runSpacing: AppSpacing.xs,
                              children: movie.genres.map((genre) {
                                return Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm,
                                    vertical: AppSpacing.xxs,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.sm,
                                    ),
                                  ),
                                  child: Text(
                                    genre,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color:
                                          theme.colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),

                SizedBox(height: AppSpacing.lg),

                // Download / Play button
                if (localFile != null)
                  SizedBox(
                    width: double.infinity,
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
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
                                  : 'Play',
                            ),
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.symmetric(
                                vertical: AppSpacing.md,
                              ),
                              backgroundColor: AppColors.success,
                            ),
                          ),
                        ),
                        SizedBox(width: AppSpacing.sm),
                        FilledButton.tonal(
                          onPressed: _isLoadingStreams
                              ? null
                              : () => _onDownloadTap(movie),
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                              vertical: AppSpacing.md,
                              horizontal: AppSpacing.md,
                            ),
                          ),
                          child: const Icon(Icons.download_rounded),
                        ),
                      ],
                    ),
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isLoadingStreams
                          ? null
                          : () => _onDownloadTap(movie),
                      icon: _isLoadingStreams
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: theme.colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.download_rounded),
                      label: Text(
                        _isLoadingStreams ? 'Loading streams...' : 'Download',
                      ),
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                      ),
                    ),
                  ),

                SizedBox(height: AppSpacing.xl),

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

class _MetadataChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? iconColor;

  const _MetadataChip({
    required this.icon,
    required this.label,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: iconColor ?? theme.colorScheme.onSurfaceVariant,
        ),
        SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
