import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../models/local_media_file.dart';
import '../providers/auto_download_provider.dart' hide nextEpisodeProvider;
import '../providers/connection_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/auto_download_service.dart';
import '../widgets/next_episode_overlay.dart';
import '../widgets/streaming_status_indicator.dart';
import '../widgets/video_controls.dart';

/// Full-screen video player screen with gesture controls
class VideoPlayerScreen extends ConsumerStatefulWidget {
  final LocalMediaFile file;
  final Duration? startPosition;

  /// Optional IMDB ID for movie playback (to fetch subtitles)
  final String? movieImdbId;

  /// Optional IMDB ID for TV show playback (to fetch subtitles)
  final String? showImdbId;

  /// Whether this file is being streamed (partially downloaded).
  /// Configures the player to tolerate incomplete data.
  final bool isStreaming;

  const VideoPlayerScreen({
    super.key,
    required this.file,
    this.startPosition,
    this.movieImdbId,
    this.showImdbId,
    this.isStreaming = false,
  });

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  bool _showControls = true;
  Timer? _hideControlsTimer;
  bool _isFullscreen = false;
  bool _showResumePrompt = false;
  Duration? _resumePosition;

  // Gesture state
  bool _isSeeking = false;
  double _seekDelta = 0;
  Offset? _dragStartPosition;
  Duration? _dragStartTime;

  // Double tap indicators
  bool _showSkipForward = false;
  bool _showSkipBackward = false;
  Timer? _skipIndicatorTimer;

  // Binge watching / Next episode state
  bool _showNextEpisodeOverlay = false;
  bool _nextEpisodeOverlayDismissed = false;
  LocalMediaFile? _nextEpisode;
  Episode? _nextEpisodeFromTmdb; // Next episode from TMDB (not downloaded yet)
  NextEpisodeResult? _nextEpisodeResult; // Full result with availability info
  int? _currentShowId;
  String? _currentImdbId;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _completedSubscription;

  // Auto-download tracking
  bool _autoDownloadTriggered = false;
  bool _nextEpisodeDownloadStarted =
      false; // Track if we started downloading next ep
  Episode? _downloadingEpisode; // The episode we're downloading
  StreamSubscription<Duration>? _autoDownloadSubscription;

  // Streaming status indicator
  StreamingStatus? _streamingStatus;
  String _streamingMessage = '';
  String? _streamingEpisodeCode;
  double? _streamingProgress;

  // Debounced buffering state for streaming mode —
  // mpv's buffering signal flickers rapidly when reading at the edge
  // of partially-downloaded data, so we smooth it out.
  bool _streamBuffering = false;
  bool _streamBufferingGrace = false; // suppress indicator right after open
  Timer? _bufferingDebounceTimer;
  StreamSubscription<bool>? _bufferingSubscription;

  @override
  void initState() {
    super.initState();
    // Delay initialization to after widget tree is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializePlayer();
      _setupNextEpisodeWatcher();
      _setupAutoDownloadWatcher();
      _setupPlaybackCompletionWatcher();
    });
  }

  Future<void> _initializePlayer() async {
    final playerService = ref.read(playerServiceProvider);

    // Set up subtitle context if movie IMDB ID is provided
    if (widget.movieImdbId != null) {
      ref
          .read(subtitleContextProvider.notifier)
          .setMovieContext(widget.movieImdbId!);
      debugPrint('[Subtitles] Set movie context: ${widget.movieImdbId}');
    }

    // Set up subtitle context if show IMDB ID is provided with episode info
    if (widget.showImdbId != null &&
        widget.file.seasonNumber != null &&
        widget.file.episodeNumber != null) {
      ref
          .read(subtitleContextProvider.notifier)
          .setSeriesContext(
            imdbId: widget.showImdbId!,
            season: widget.file.seasonNumber!,
            episode: widget.file.episodeNumber!,
          );
      debugPrint(
        '[Subtitles] Set series context from widget: ${widget.showImdbId} S${widget.file.seasonNumber}E${widget.file.episodeNumber}',
      );
    }

    // Check for existing progress
    final existingProgress = ref.read(
      fileWatchProgressProvider(widget.file.path),
    );

    // For streaming: set up debounced buffering BEFORE opening the file so
    // we don't miss any initial buffering events from mpv.
    if (widget.isStreaming) {
      _setupStreamingBufferingDebounce();
    }

    if (existingProgress != null &&
        existingProgress.progress > 0.05 &&
        existingProgress.progress < 0.95 &&
        widget.startPosition == null) {
      // Show resume prompt
      setState(() {
        _showResumePrompt = true;
        _resumePosition = existingProgress.position;
      });
    } else {
      // Start playing immediately
      await playerService.openFile(
        widget.file,
        startPosition: widget.startPosition,
        isStreaming: widget.isStreaming,
      );
    }

    _startHideControlsTimer();
  }

  static const _bufferingShowDelay = Duration(milliseconds: 400);
  static const _bufferingHideDelay = Duration(seconds: 1);
  static const _firstPlayTimeout = Duration(seconds: 15);
  static const _postPlayGrace = Duration(seconds: 1);

  /// Smooth out mpv's rapid buffering signal during streaming.
  ///
  /// • Suppress the indicator until mpv actually starts playing (dynamic grace
  ///   period), plus 1 s stabilisation — avoids a second "loading" right after
  ///   the streaming overlay just disappeared.
  /// • Show the indicator only after buffering has been true for 400 ms
  ///   (ignores sub-second micro-stalls).
  /// • Once shown, keep it visible for at least 1 s after buffering clears
  ///   (prevents rapid on/off flicker).
  void _setupStreamingBufferingDebounce() {
    // Grace period — suppress indicator until mpv actually starts playing,
    // rather than using a fixed timer that may expire too early for large files.
    _streamBufferingGrace = true;
    final playerService = ref.read(playerServiceProvider);
    playerService.waitForFirstPlay(timeout: _firstPlayTimeout).then((_) {
      // Extra stabilisation after first play to absorb initial decode stalls.
      Future.delayed(_postPlayGrace, () {
        if (mounted) setState(() => _streamBufferingGrace = false);
      });
    });

    final player = ref.read(playerProvider);
    _bufferingSubscription = player.stream.buffering.listen((isBuffering) {
      if (!mounted) return;
      _bufferingDebounceTimer?.cancel();

      if (isBuffering && !_streamBuffering) {
        // Delay showing — ignore very short stalls
        _bufferingDebounceTimer = Timer(_bufferingShowDelay, () {
          if (mounted) setState(() => _streamBuffering = true);
        });
      } else if (!isBuffering && _streamBuffering) {
        // Delay hiding — avoid flicker when buffering toggles rapidly
        _bufferingDebounceTimer = Timer(_bufferingHideDelay, () {
          if (mounted) setState(() => _streamBuffering = false);
        });
      }
    });
  }

  void _setupNextEpisodeWatcher() async {
    final player = ref.read(playerProvider);
    final bingeWatchingEnabled = ref.read(bingeWatchingEnabledProvider);

    if (!bingeWatchingEnabled) return;

    // Always check TMDB first to know what the ACTUAL next episode should be
    // This ensures we don't skip episodes (e.g., showing E05 when E04 is missing)
    await _checkTmdbForNextEpisode();

    // If TMDB found a next episode, check if it's downloaded
    if (_nextEpisodeFromTmdb != null) {
      final showName = widget.file.showName;
      if (showName != null) {
        final scanner = ref.read(localMediaScannerProvider);
        final files = await scanner.scanDirectory();

        final downloadedNextEp = scanner.findEpisodeFile(
          files,
          showName: showName,
          season: _nextEpisodeFromTmdb!.seasonNumber,
          episode: _nextEpisodeFromTmdb!.episodeNumber,
        );

        if (downloadedNextEp != null) {
          // The actual next episode IS downloaded - use it
          debugPrint(
            '[NextEpisode] Found downloaded next episode: ${downloadedNextEp.fileName}',
          );
          setState(() {
            _nextEpisode = downloadedNextEp;
            _nextEpisodeFromTmdb = null; // Clear TMDB since we have the file
          });
        } else {
          debugPrint(
            '[NextEpisode] Next episode S${_nextEpisodeFromTmdb!.seasonNumber}E${_nextEpisodeFromTmdb!.episodeNumber} not downloaded - will offer download',
          );
        }
      }
    } else {
      // TMDB didn't find next episode, fall back to local check
      // This handles cases where TMDB lookup fails
      _nextEpisode = ref.read(nextEpisodeProvider(widget.file));
    }

    // Only proceed if we have either a downloaded episode or TMDB info
    final hasNextEpisode = _nextEpisode != null || _nextEpisodeFromTmdb != null;
    if (!hasNextEpisode) return;

    // Watch position to show next episode overlay
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted || _nextEpisodeOverlayDismissed) return;

      final duration = player.state.duration;
      if (duration.inSeconds <= 0) return;

      final countdownSeconds = ref.read(nextEpisodeCountdownSecondsProvider);
      final remaining = duration - position;

      // Show overlay when remaining time equals countdown seconds
      if (remaining.inSeconds <= countdownSeconds &&
          remaining.inSeconds > 0 &&
          !_showNextEpisodeOverlay &&
          !_showResumePrompt) {
        setState(() {
          _showNextEpisodeOverlay = true;
        });
      }
    });
  }

  /// Check TMDB for next episode when no downloaded episode is available
  Future<void> _checkTmdbForNextEpisode() async {
    final file = widget.file;
    final showName = file.showName;
    final season = file.seasonNumber;
    final episode = file.episodeNumber;

    debugPrint(
      '[AutoDownload] Checking TMDB for next episode: $showName S${season}E$episode',
    );

    if (showName == null || season == null || episode == null) {
      debugPrint('[AutoDownload] Missing show info, skipping TMDB check');
      return;
    }

    try {
      final tmdbService = ref.read(tmdbServiceProvider);
      final shows = await tmdbService.searchShows(showName);

      debugPrint(
        '[AutoDownload] TMDB search results: ${shows.length} shows found',
      );

      if (shows.isEmpty) return;

      final show = shows.first;
      _currentShowId = show.id;

      // Get full show details with IMDB ID (using append_to_response for external_ids)
      final showDetails = await tmdbService.getShowDetailsWithImdb(show.id);
      _currentImdbId = showDetails.imdbId;

      debugPrint(
        '[AutoDownload] Show: ${show.name}, TMDB ID: ${show.id}, IMDB ID: $_currentImdbId',
      );

      // Set subtitle context for OpenSubtitles
      if (_currentImdbId != null && season != null && episode != null) {
        ref
            .read(subtitleContextProvider.notifier)
            .setSeriesContext(
              imdbId: _currentImdbId!,
              season: season,
              episode: episode,
            );
        debugPrint(
          '[Subtitles] Set series context: $_currentImdbId S${season}E$episode',
        );
      }

      // Use auto-download service to get next episode info
      final autoDownloadService = ref.read(autoDownloadServiceProvider);
      final result = await autoDownloadService.getNextEpisode(
        showId: show.id,
        currentSeason: season,
        currentEpisode: episode,
      );

      debugPrint(
        '[AutoDownload] Next episode result: ${result.nextEpisode?.episodeCode ?? "none"}, hasNext: ${result.hasNextEpisode}',
      );

      if (mounted) {
        setState(() {
          _nextEpisodeResult = result;
          _nextEpisodeFromTmdb = result.nextEpisode;
        });
      }
    } catch (e) {
      debugPrint('[AutoDownload] Failed to check TMDB for next episode: $e');
    }
  }

  void _setupAutoDownloadWatcher() {
    final player = ref.read(playerProvider);
    final autoDownloadState = ref.read(autoDownloadProvider);

    // Only setup auto-download if BOTH enabled AND downloadOnProgress are true
    // User must explicitly enable auto-download in settings
    if (!autoDownloadState.enabled) {
      debugPrint('[AutoDownload] Auto-download disabled in settings');
      return;
    }
    if (!autoDownloadState.downloadOnProgress) {
      debugPrint('[AutoDownload] Download on progress disabled in settings');
      return;
    }

    debugPrint(
      '[AutoDownload] Auto-download enabled, threshold: ${autoDownloadState.progressThreshold}',
    );

    // Watch position to trigger auto-download at threshold
    _autoDownloadSubscription = player.stream.position.listen((position) {
      if (!mounted || _autoDownloadTriggered) return;

      // Re-check settings in case user disabled during playback
      final currentState = ref.read(autoDownloadProvider);
      if (!currentState.enabled || !currentState.downloadOnProgress) return;

      final duration = player.state.duration;
      if (duration.inSeconds <= 0) return;

      final progress = position.inMilliseconds / duration.inMilliseconds;

      // Trigger auto-download when progress reaches threshold
      if (progress >= currentState.progressThreshold) {
        _autoDownloadTriggered = true;
        _triggerAutoDownload();
      }
    });
  }

  Future<void> _triggerAutoDownload() async {
    final file = widget.file;

    // Need show ID and IMDB ID - try to look them up from local media
    final showName = file.showName;
    final season = file.seasonNumber;
    final episode = file.episodeNumber;
    final quality = file.quality ?? '1080p';

    if (showName == null || season == null || episode == null) return;

    // Try to find the show ID from TMDB
    try {
      final tmdbService = ref.read(tmdbServiceProvider);
      final shows = await tmdbService.searchShows(showName);

      if (shows.isEmpty) return;

      final show = shows.first;
      final showDetails = await tmdbService.getShowDetails(show.id);

      // Trigger auto-download
      ref
          .read(autoDownloadProvider.notifier)
          .onWatchProgress(
            showId: show.id,
            imdbId: showDetails.imdbId,
            showName: showName,
            season: season,
            episode: episode,
            progress: ref.read(autoDownloadProvider).progressThreshold,
            currentQuality: quality,
          );
    } catch (e) {
      debugPrint('Auto-download trigger failed: $e');
    }
  }

  /// Watch for playback completion to auto-play next episode if available
  void _setupPlaybackCompletionWatcher() {
    final player = ref.read(playerProvider);

    _completedSubscription = player.stream.completed.listen((completed) async {
      if (!completed || !mounted) return;

      debugPrint(
        '[AutoDownload] Playback completed, checking for next episode...',
      );

      // If we started downloading the next episode, check if it's ready
      if (_nextEpisodeDownloadStarted && _downloadingEpisode != null) {
        debugPrint(
          '[AutoDownload] Next episode download was started, checking if ready...',
        );
        await _tryPlayDownloadedNextEpisode();
        return;
      }

      // Also check if a downloaded next episode exists (may have been downloaded in background)
      await _checkAndPlayNextEpisode();
    });
  }

  /// Try to play the next episode that was being downloaded
  Future<void> _tryPlayDownloadedNextEpisode() async {
    final episode = _downloadingEpisode;
    if (episode == null) return;

    final showName = widget.file.showName;
    if (showName == null) return;

    debugPrint(
      '[AutoDownload] Looking for downloaded file: $showName S${episode.seasonNumber}E${episode.episodeNumber}',
    );

    // Refresh local files to find newly downloaded episode
    final refreshMedia = ref.read(refreshLocalMediaProvider);
    await refreshMedia();

    // Small delay to ensure file is detected
    await Future.delayed(const Duration(seconds: 2));

    // Re-scan for the episode
    final scanner = ref.read(localMediaScannerProvider);
    final files = await scanner.scanDirectory();

    final nextFile = scanner.findEpisodeFile(
      files,
      showName: showName,
      season: episode.seasonNumber,
      episode: episode.episodeNumber,
    );

    if (nextFile != null && mounted) {
      debugPrint(
        '[AutoDownload] Found downloaded episode! Playing: ${nextFile.fileName}',
      );

      // Dismiss any streaming indicator
      _dismissStreamingStatus();

      final playerService = ref.read(playerServiceProvider);
      await playerService.stop();

      final fileToPlay = nextFile; // Capture non-null value
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: fileToPlay)),
      );
    } else {
      debugPrint(
        '[AutoDownload] Downloaded file not found yet - may still be downloading',
      );
      // Show message that file is still downloading
      if (mounted) {
        _showStreamingStatus(
          status: StreamingStatus.buffering,
          message: 'Still downloading. Check Library when ready.',
          episodeCode: episode.episodeCode,
        );
      }
    }
  }

  /// Check if next episode has been downloaded (background download) and play it
  Future<void> _checkAndPlayNextEpisode() async {
    final showName = widget.file.showName;
    final currentSeason = widget.file.seasonNumber;
    final currentEpisode = widget.file.episodeNumber;

    if (showName == null || currentSeason == null || currentEpisode == null)
      return;

    // Calculate next episode number
    final nextEpisodeNum = currentEpisode + 1;

    debugPrint(
      '[AutoDownload] Checking for next episode: $showName S${currentSeason}E$nextEpisodeNum',
    );

    // Refresh local files
    final scanner = ref.read(localMediaScannerProvider);
    final files = await scanner.scanDirectory();

    // Try current season next episode first
    var nextFile = scanner.findEpisodeFile(
      files,
      showName: showName,
      season: currentSeason,
      episode: nextEpisodeNum,
    );

    // If not found, try first episode of next season
    if (nextFile == null) {
      nextFile = scanner.findEpisodeFile(
        files,
        showName: showName,
        season: currentSeason + 1,
        episode: 1,
      );
    }

    if (nextFile != null && mounted) {
      debugPrint(
        '[AutoDownload] Found next episode! Playing: ${nextFile.fileName}',
      );

      final playerService = ref.read(playerServiceProvider);
      await playerService.stop();

      final fileToPlay = nextFile; // Capture non-null value
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: fileToPlay)),
      );
    }
  }

  void _onPlayNextEpisode() async {
    _positionSubscription?.cancel();
    _dismissStreamingStatus();

    final nextEpisode = _nextEpisode;
    if (nextEpisode == null) return;

    // Stop current playback
    final playerService = ref.read(playerServiceProvider);
    await playerService.stop();

    if (mounted) {
      // Navigate to next episode
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: nextEpisode)),
      );
    }
  }

  void _onCancelNextEpisode() {
    setState(() {
      _showNextEpisodeOverlay = false;
      _nextEpisodeOverlayDismissed = true;
    });
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  void _onUserInteraction() {
    setState(() => _showControls = true);
    _startHideControlsTimer();
  }

  Future<void> _toggleFullscreen() async {
    // Snapshot selected subtitles before the window resizes — on some
    // platforms the video surface is recreated during fullscreen transitions
    // and mpv drops the active external/embedded track. We re-apply below.
    final externalSub = ref.read(currentExternalSubtitleProvider);
    final embeddedSub = ref.read(playerProvider).state.track.subtitle;

    final newFullscreen = !_isFullscreen;
    setState(() => _isFullscreen = newFullscreen);
    await windowManager.setFullScreen(newFullscreen);

    // Let the surface settle, then restore whichever subtitle was selected.
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    final playerService = ref.read(playerServiceProvider);
    if (externalSub != null) {
      await playerService.loadExternalSubtitle(externalSub.url);
    } else if (embeddedSub != SubtitleTrack.no() &&
        embeddedSub != SubtitleTrack.auto()) {
      await playerService.setSubtitleTrack(embeddedSub);
    }
  }

  Future<void> _handleResume(bool resume) async {
    setState(() => _showResumePrompt = false);

    final playerService = ref.read(playerServiceProvider);
    await playerService.openFile(
      widget.file,
      startPosition: resume ? _resumePosition : null,
      isStreaming: widget.isStreaming,
    );
  }

  Future<void> _exitPlayer() async {
    final playerService = ref.read(playerServiceProvider);
    await playerService.stop();
    if (_isFullscreen) {
      await windowManager.setFullScreen(false);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  // Handle horizontal swipe to seek
  void _onHorizontalDragStart(DragStartDetails details) {
    final player = ref.read(playerProvider);
    setState(() {
      _isSeeking = true;
      _seekDelta = 0;
      _dragStartPosition = details.globalPosition;
      _dragStartTime = player.state.position;
    });
    _onUserInteraction();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_isSeeking || _dragStartPosition == null) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final dragDistance = details.globalPosition.dx - _dragStartPosition!.dx;

    // Each 100 pixels = 10 seconds
    final seekSeconds = (dragDistance / 100) * 10;

    setState(() {
      _seekDelta = seekSeconds;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_isSeeking || _dragStartTime == null) return;

    final newPosition = _dragStartTime! + Duration(seconds: _seekDelta.round());
    final clampedPosition = newPosition.isNegative
        ? Duration.zero
        : newPosition;

    ref.read(playerServiceProvider).seek(clampedPosition);

    setState(() {
      _isSeeking = false;
      _seekDelta = 0;
      _dragStartPosition = null;
      _dragStartTime = null;
    });
  }

  // Handle double tap to skip
  void _onDoubleTapDown(TapDownDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    if (tapX < screenWidth / 3) {
      // Left third - skip backward 10s
      _showSkipIndicator(forward: false);
      ref.read(playerServiceProvider).seekBackward(seconds: 10);
    } else if (tapX > screenWidth * 2 / 3) {
      // Right third - skip forward 10s
      _showSkipIndicator(forward: true);
      ref.read(playerServiceProvider).seekForward(seconds: 10);
    } else {
      // Center - toggle play/pause
      ref.read(playerServiceProvider).playOrPause();
    }
    _onUserInteraction();
  }

  void _showSkipIndicator({required bool forward}) {
    _skipIndicatorTimer?.cancel();
    setState(() {
      _showSkipForward = forward;
      _showSkipBackward = !forward;
    });
    _skipIndicatorTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _showSkipForward = false;
          _showSkipBackward = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _skipIndicatorTimer?.cancel();
    _positionSubscription?.cancel();
    _completedSubscription?.cancel();
    _autoDownloadSubscription?.cancel();
    _bufferingDebounceTimer?.cancel();
    _bufferingSubscription?.cancel();
    // Note: Don't use ref.read() in dispose - providers will clean up themselves
    // Exit fullscreen on dispose
    windowManager.setFullScreen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final videoController = ref.watch(videoControllerProvider);
    final isPlaying = ref.watch(isPlayingProvider).value ?? false;
    final rawBuffering = ref.watch(isBufferingProvider).value ?? false;

    // When streaming, use the debounced buffering state (with grace period)
    // to avoid the indicator flickering every time mpv hits the download edge.
    final isBuffering = widget.isStreaming
        ? (_streamBuffering && !_streamBufferingGrace)
        : rawBuffering;

    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        onKeyEvent: (event) => _handleKeyEvent(event, ref),
        child: MouseRegion(
          cursor: _showControls ? MouseCursor.defer : SystemMouseCursors.none,
          onHover: (_) => _onUserInteraction(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Main video area with gesture detection
              GestureDetector(
                onTap: _showNextEpisodeOverlay ? null : _onUserInteraction,
                onDoubleTapDown: _showNextEpisodeOverlay
                    ? null
                    : _onDoubleTapDown,
                onHorizontalDragStart: _showNextEpisodeOverlay
                    ? null
                    : _onHorizontalDragStart,
                onHorizontalDragUpdate: _showNextEpisodeOverlay
                    ? null
                    : _onHorizontalDragUpdate,
                onHorizontalDragEnd: _showNextEpisodeOverlay
                    ? null
                    : _onHorizontalDragEnd,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Video
                    Video(
                      controller: videoController,
                      controls: NoVideoControls,
                    ),

                    // Buffering indicator
                    if (isBuffering) const _BufferingIndicator(),

                    // Skip backward indicator (left side)
                    if (_showSkipBackward)
                      Positioned(
                        left: 60,
                        top: 0,
                        bottom: 0,
                        child: Center(child: _buildSkipIndicator(false)),
                      ),

                    // Skip forward indicator (right side)
                    if (_showSkipForward)
                      Positioned(
                        right: 60,
                        top: 0,
                        bottom: 0,
                        child: Center(child: _buildSkipIndicator(true)),
                      ),

                    // Seek indicator during drag
                    if (_isSeeking) Center(child: _buildSeekIndicator()),

                    // Resume prompt overlay
                    if (_showResumePrompt) _buildResumePrompt(),

                    // Custom controls overlay
                    if (!_showResumePrompt)
                      AnimatedOpacity(
                        opacity: _showControls ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 300),
                        child: IgnorePointer(
                          ignoring: !_showControls,
                          child: VideoControlsOverlay(
                            file: widget.file,
                            isPlaying: isPlaying,
                            isFullscreen: _isFullscreen,
                            onPlayPause: () =>
                                ref.read(playerServiceProvider).playOrPause(),
                            onSeekForward: () =>
                                ref.read(playerServiceProvider).seekForward(),
                            onSeekBackward: () =>
                                ref.read(playerServiceProvider).seekBackward(),
                            onToggleFullscreen: _toggleFullscreen,
                            onClose: _exitPlayer,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Next episode overlay (OUTSIDE of GestureDetector so buttons work)
              if (_showNextEpisodeOverlay &&
                  (_nextEpisode != null || _nextEpisodeFromTmdb != null))
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.5),
                    child: _nextEpisode != null
                        ? NextEpisodeOverlay(
                            nextEpisode: _nextEpisode!,
                            countdownSeconds: ref.read(
                              nextEpisodeCountdownSecondsProvider,
                            ),
                            onPlayNext: _onPlayNextEpisode,
                            onCancel: _onCancelNextEpisode,
                          )
                        : _buildTmdbNextEpisodeOverlay(),
                  ),
                ),

              // Streaming status indicator (top of screen, inside player)
              if (_streamingStatus != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + AppSpacing.md,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: StreamingStatusIndicator(
                        status: _streamingStatus!,
                        message: _streamingMessage,
                        episodeCode: _streamingEpisodeCode,
                        progress: _streamingProgress,
                        onDismiss: _dismissStreamingStatus,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _dismissStreamingStatus() {
    if (mounted) {
      setState(() {
        _streamingStatus = null;
        _streamingMessage = '';
        _streamingEpisodeCode = null;
        _streamingProgress = null;
      });
    }
  }

  void _showStreamingStatus({
    required StreamingStatus status,
    required String message,
    String? episodeCode,
    double? progress,
  }) {
    if (mounted) {
      setState(() {
        _streamingStatus = status;
        _streamingMessage = message;
        _streamingEpisodeCode = episodeCode;
        _streamingProgress = progress;
      });
    }
  }

  Widget _buildSkipIndicator(bool forward) {
    return _SkipRippleIndicator(forward: forward);
  }

  Widget _buildSeekIndicator() {
    final isForward = _seekDelta >= 0;
    final seconds = _seekDelta.abs().round();
    final targetTime = _dragStartTime! + Duration(seconds: _seekDelta.round());

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isForward ? Icons.forward_rounded : Icons.replay_rounded,
                color: Colors.white,
                size: 28,
              ),
              const SizedBox(width: 8),
              Text(
                '${isForward ? '+' : '-'}${seconds}s',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _formatDuration(targetTime.isNegative ? Duration.zero : targetTime),
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResumePrompt() {
    final theme = Theme.of(context);

    return Container(
      color: Colors.black87,
      child: Center(
        child: Card(
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_circle_rounded,
                    size: 40,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                SizedBox(height: AppSpacing.lg),
                Text(
                  'Resume playback?',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: AppSpacing.xs),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    'Last position: ${_formatDuration(_resumePosition ?? Duration.zero)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(height: AppSpacing.xl),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.replay_rounded),
                      label: const Text('Start Over'),
                      onPressed: () => _handleResume(false),
                    ),
                    SizedBox(width: AppSpacing.md),
                    FilledButton.icon(
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Resume'),
                      onPressed: () => _handleResume(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Build overlay for next episode that isn't downloaded yet (from TMDB)
  Widget _buildTmdbNextEpisodeOverlay() {
    final theme = Theme.of(context);
    final episode = _nextEpisodeFromTmdb;
    final result = _nextEpisodeResult;

    if (episode == null) return const SizedBox.shrink();

    final isAvailableToDownload = result?.hasNextEpisode == true;
    final message = result?.message;

    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: EdgeInsets.only(right: AppSpacing.lg, bottom: 100),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 340,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.9),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.3),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondary.withOpacity(0.2),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(AppRadius.lg),
                      topRight: Radius.circular(AppRadius.lg),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isAvailableToDownload
                            ? Icons.download_rounded
                            : Icons.schedule_rounded,
                        color: theme.colorScheme.secondary,
                        size: 20,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          isAvailableToDownload
                              ? 'Next Episode Available'
                              : 'Up Next',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Episode info
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        episode.episodeCode,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        episode.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (message != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            message,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Action buttons
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _onCancelNextEpisode,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          child: const Text('Dismiss'),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      if (isAvailableToDownload)
                        Expanded(
                          flex: 2,
                          child: FilledButton.icon(
                            onPressed: _onStreamNextEpisode,
                            icon: const Icon(
                              Icons.play_circle_outline_rounded,
                              size: 20,
                            ),
                            label: const Text('Stream'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Stream the next episode from TMDB/EZTV
  Future<void> _onStreamNextEpisode() async {
    debugPrint('[Streaming] Stream button pressed');
    final episode = _nextEpisodeFromTmdb;
    debugPrint(
      '[Streaming] Episode: ${episode?.episodeCode}, IMDB: $_currentImdbId',
    );

    if (episode == null || _currentImdbId == null) {
      debugPrint('[Streaming] Missing episode or IMDB ID, canceling');
      _onCancelNextEpisode();
      return;
    }

    final autoDownloadService = ref.read(autoDownloadServiceProvider);
    final settings = ref.read(settingsProvider);
    final quality =
        widget.file.quality ?? ref.read(autoDownloadProvider).defaultQuality;

    debugPrint(
      '[Streaming] Searching for torrent: S${episode.seasonNumber}E${episode.episodeNumber} quality: $quality',
    );

    // Dismiss overlay immediately so user sees progress
    _onCancelNextEpisode();

    // Show searching indicator
    _showStreamingStatus(
      status: StreamingStatus.searching,
      message: 'Finding torrent...',
      episodeCode: episode.episodeCode,
    );

    // Find torrent for the episode
    final torrent = await autoDownloadService.findTorrentForEpisode(
      imdbId: _currentImdbId!,
      season: episode.seasonNumber,
      episode: episode.episodeNumber,
      preferredQuality: quality,
    );

    if (!mounted) return;

    debugPrint('[Streaming] Torrent found: ${torrent?.title ?? "null"}');

    if (torrent == null) {
      _showStreamingStatus(
        status: StreamingStatus.error,
        message: 'No torrent found',
        episodeCode: episode.episodeCode,
      );
      return;
    }

    debugPrint(
      '[Streaming] Starting stream download: ${torrent.magnetUrl.substring(0, 50)}...',
    );
    if (torrent.fileIdx != null) {
      debugPrint(
        '[Streaming] Season pack detected - will select file index: ${torrent.fileIdx}',
      );
    }

    // Start download with sequential mode for streaming
    final success = await autoDownloadService.downloadNextEpisode(
      magnetLink: torrent.magnetUrl,
      savePath: settings.defaultSavePath,
      infoHash: torrent.hash,
      fileIdx: torrent.fileIdx,
    );

    if (!mounted) return;

    debugPrint('[Streaming] Stream started: $success');

    if (success) {
      // Track the show for future auto-downloads
      if (_currentShowId != null) {
        ref
            .read(autoDownloadProvider.notifier)
            .trackShow(
              showId: _currentShowId!,
              imdbId: _currentImdbId,
              showName: widget.file.showName ?? '',
              season: episode.seasonNumber,
              episode: episode.episodeNumber,
              quality: torrent.quality,
            );
      }

      // Track that we started downloading this episode
      setState(() {
        _nextEpisodeDownloadStarted = true;
        _downloadingEpisode = episode;
      });

      // Show buffering status
      _showStreamingStatus(
        status: StreamingStatus.buffering,
        message: 'Buffering started',
        episodeCode: episode.episodeCode,
        progress: 0.0,
      );

      // Start monitoring stream readiness for next episode
      _monitorNextEpisodeStream(torrent.magnetUrl, episode);
    } else {
      _showStreamingStatus(
        status: StreamingStatus.error,
        message: 'Failed to start stream',
        episodeCode: episode.episodeCode,
      );
    }
  }

  /// Monitor streaming progress for the next episode
  Future<void> _monitorNextEpisodeStream(
    String magnetUrl,
    Episode episode,
  ) async {
    final qbtService = ref.read(qbApiServiceProvider);

    // Wait a moment for qBittorrent to process the magnet
    await Future.delayed(const Duration(seconds: 3));

    // Poll for torrent progress
    for (int i = 0; i < 120; i++) {
      // Max 10 minutes
      await Future.delayed(const Duration(seconds: 5));

      if (!mounted) return;

      // Find the torrent by matching the magnet hash
      final torrents = await qbtService.getTorrents();
      final torrent = torrents.firstWhereOrNull(
        (t) => magnetUrl.toLowerCase().contains(t.hash.toLowerCase()),
      );

      if (torrent == null) continue;

      // Update progress in the indicator
      _showStreamingStatus(
        status: StreamingStatus.buffering,
        message: 'Buffering...',
        episodeCode: episode.episodeCode,
        progress: torrent.progress,
      );

      // Check if ready for streaming
      final isReady = await qbtService.isReadyForStreaming(
        torrent.hash,
        minProgress: 0.05,
      );

      if (isReady && mounted) {
        // Update the next episode to the downloaded file
        final videoFile = await _findVideoFileInPath(torrent.contentPath);
        if (videoFile != null) {
          setState(() {
            _nextEpisode = videoFile;
            _nextEpisodeFromTmdb = null; // Clear TMDB version
          });

          // Show ready status
          _showStreamingStatus(
            status: StreamingStatus.ready,
            message: 'Ready to play!',
            episodeCode: episode.episodeCode,
          );
        }
        return;
      }
    }

    // Timeout - dismiss indicator
    _dismissStreamingStatus();
  }

  /// Find video file in a content path
  Future<LocalMediaFile?> _findVideoFileInPath(String contentPath) async {
    try {
      final fileOrDir = FileSystemEntity.typeSync(contentPath);
      List<File> videoFiles = [];

      if (fileOrDir == FileSystemEntityType.file) {
        final ext = contentPath.split('.').last.toLowerCase();
        if (videoExtensions.contains(ext)) {
          videoFiles.add(File(contentPath));
        }
      } else if (fileOrDir == FileSystemEntityType.directory) {
        final dir = Directory(contentPath);
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

  void _handleKeyEvent(KeyEvent event, WidgetRef ref) {
    if (event is! KeyDownEvent) return;

    final playerService = ref.read(playerServiceProvider);

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        playerService.playOrPause();
        _onUserInteraction();
        break;
      case LogicalKeyboardKey.arrowLeft:
        playerService.seekBackward(seconds: 10);
        _onUserInteraction();
        break;
      case LogicalKeyboardKey.arrowRight:
        playerService.seekForward(seconds: 10);
        _onUserInteraction();
        break;
      case LogicalKeyboardKey.arrowUp:
        final player = ref.read(playerProvider);
        playerService.setVolume((player.state.volume + 10).clamp(0, 100));
        _onUserInteraction();
        break;
      case LogicalKeyboardKey.arrowDown:
        final player = ref.read(playerProvider);
        playerService.setVolume((player.state.volume - 10).clamp(0, 100));
        _onUserInteraction();
        break;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        break;
      case LogicalKeyboardKey.keyM:
        playerService.toggleMute();
        _onUserInteraction();
        break;
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          _toggleFullscreen();
        } else {
          _exitPlayer();
        }
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// Skip ripple indicator — Netflix-style double-tap feedback
// ---------------------------------------------------------------------------

class _SkipRippleIndicator extends StatefulWidget {
  final bool forward;
  const _SkipRippleIndicator({required this.forward});

  @override
  State<_SkipRippleIndicator> createState() => _SkipRippleIndicatorState();
}

class _SkipRippleIndicatorState extends State<_SkipRippleIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
    _scale = Tween<double>(
      begin: 0.7,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_ctrl);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Opacity(
          opacity: _opacity.value,
          child: Transform.scale(
            scale: _scale.value,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.50),
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.forward) ...[
                    Icon(
                      Icons.replay_10_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '10s',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ] else ...[
                    const Text(
                      '10s',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.forward_10_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Buffering indicator — branded, frosted-glass feel
// ---------------------------------------------------------------------------

class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          shape: BoxShape.circle,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(
              Colors.white.withOpacity(0.9),
            ),
          ),
        ),
      ),
    );
  }
}
