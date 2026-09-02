import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../providers/local_media_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/app_logger.dart';
import '../services/local_streaming_server.dart';
import '../services/next_episode_planner.dart';
import '../services/streaming_service.dart';
import '../widgets/next_episode_overlay.dart';
import '../widgets/player/buffering_indicator.dart';
import '../widgets/player/player_keyboard.dart';
import '../widgets/player/resume_prompt.dart';
import '../widgets/player/seek_indicator.dart';
import '../widgets/player/skip_ripple_indicator.dart';
import '../widgets/streaming_status_indicator.dart';
import '../widgets/video_controls.dart';
import '_player_next_episode_controller.dart';
import '_player_streaming_health.dart';

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

  /// qBittorrent info-hash for the torrent backing this stream, used by the
  /// PlaybackHealthMonitor to track download edge and prevent over-read into
  /// sparse (zero-filled) regions. Only meaningful when [isStreaming] is true.
  final String? streamingTorrentHash;

  /// Index of the target file within the torrent (matches qBittorrent's file
  /// list order). Used alongside [streamingTorrentHash]. Only meaningful when
  /// [isStreaming] is true.
  final int? streamingFileIndex;

  /// Optional `http://127.0.0.1:.../...` URL served by [LocalStreamingServer].
  /// When set and [isStreaming] is true, the player opens this URL instead
  /// of [file.path] — mpv reads through the proxy so it doesn't choke on
  /// the zero-padded sparse regions of the partial file on disk.
  final String? streamingProxyUrl;

  /// File download fraction (0.0–1.0) at the moment we navigate to the
  /// player. Used to seed the seek-bar's buffered track immediately so
  /// the user sees how much is downloaded as soon as the player opens,
  /// instead of waiting ~2 s for the first health-poll to land.
  final double? initialBufferedRatio;

  /// Id of the [StreamingSession] backing this playback, when there is one.
  ///
  /// Ownership, not decoration: whoever holds the id is responsible for
  /// cancelling the session, which is what tears down its
  /// [LocalStreamingServer] and releases the loopback port. Nothing cancelled
  /// sessions before this existed, so every play leaked an HTTP server for
  /// the life of the process.
  final String? streamingSessionId;

  const VideoPlayerScreen({
    super.key,
    required this.file,
    this.startPosition,
    this.movieImdbId,
    this.showImdbId,
    this.isStreaming = false,
    this.streamingTorrentHash,
    this.streamingFileIndex,
    this.streamingProxyUrl,
    this.initialBufferedRatio,
    this.streamingSessionId,
  });

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen>
    with
        PlayerNextEpisodeController<VideoPlayerScreen>,
        PlayerStreamingHealth<VideoPlayerScreen> {
  bool _showControls = true;
  Timer? _hideControlsTimer;
  bool _isFullscreen = false;

  /// Window size captured the first time we go into fullscreen — used
  /// to restore the user's prior window size on exit. macOS in
  /// particular will not preserve the previous bounds when leaving
  /// `setFullScreen(false)`, so we replay it ourselves.
  Size? _preFullscreenSize;
  bool _showResumePrompt = false;
  Duration? _resumePosition;
  bool _mediaOpened = false;
  bool _exiting = false;
  late final FocusNode _keyboardFocus;

  // Gesture state
  bool _isSeeking = false;
  double _seekDelta = 0;
  Offset? _dragStartPosition;
  Duration? _dragStartTime;

  // Double tap indicators
  bool _showSkipForward = false;
  bool _showSkipBackward = false;
  Timer? _skipIndicatorTimer;

  // Binge watching. The *when* — trigger window, overlay-vs-autoplay and
  // the one-shot guards — lives in [NextEpisodePlanner]; the *what* —
  // resolving the episode, the TMDB lookup, the prefetch and the hand-off —
  // lives in [PlayerNextEpisodeController]. This screen holds the planner
  // only because `build()` reads it to decide whether to draw the overlay.
  late final NextEpisodePlanner _planner;

  /// Captured in [initState] so [dispose] can reach it without `ref.read`,
  /// which is not safe there.
  late final StreamingSessionsNotifier _streamingSessions;

  /// Streaming sessions this screen must tear down on dispose. Set to null
  /// the moment a session is handed to a replacement screen — that screen
  /// takes ownership with it, and cancelling here would kill the proxy the
  /// next episode is about to read from.
  String? _ownedSessionId;
  @override
  void initState() {
    super.initState();
    _streamingSessions = ref.read(streamingSessionsProvider.notifier);
    _ownedSessionId = widget.streamingSessionId;
    _keyboardFocus = FocusNode();
    _planner = NextEpisodePlanner(
      bingeEnabled: ref.read(bingeWatchingEnabledProvider),
    );
    // Seed the buffered-ratio from whatever the streaming session knew at
    // navigation time so the seek-bar's buffered track is populated on the
    // first frame instead of going dark for ~2 s until the first health
    // poll lands. Updated continuously thereafter by [PlaybackHealthMonitor].
    if (widget.isStreaming && widget.initialBufferedRatio != null) {
      streamingDownloadedRatio = widget.initialBufferedRatio!.clamp(0.0, 1.0);
    }
    // Delay initialization to after widget tree is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
      _initializePlayer();
      setupNextEpisodeWatcher();
      setupAutoDownloadWatcher();
      setupPlaybackCompletionWatcher();
    });
  }

  Future<void> _initializePlayer() async {
    final playerService = ref.read(playerServiceProvider);

    // Set up subtitle context if movie IMDB ID is provided
    if (widget.movieImdbId != null) {
      ref
          .read(subtitleContextProvider.notifier)
          .setMovieContext(widget.movieImdbId!);
      AppLog.d('[Subtitles] Set movie context: ${widget.movieImdbId}');
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
      AppLog.d(
        '[Subtitles] Set series context from widget: ${widget.showImdbId} S${widget.file.seasonNumber}E${widget.file.episodeNumber}',
      );
    }

    // Check for existing progress
    final existingProgress = ref.read(
      fileWatchProgressProvider(widget.file.path),
    );

    if (existingProgress != null &&
        existingProgress.progress > 0.05 &&
        !existingProgress.shouldMarkCompleted &&
        widget.startPosition == null) {
      // Show resume prompt — streaming UI is wired up later in _handleResume
      // once the user picks a start position, so the same post-open ordering
      // is preserved there.
      setState(() {
        _showResumePrompt = true;
        _resumePosition = existingProgress.position;
      });
    } else {
      if (widget.isStreaming) {
        AppLog.d(
          '[VideoPlayerScreen] opening streaming hash=${widget.streamingTorrentHash} '
          'fileIdx=${widget.streamingFileIndex} '
          'proxyUrl=${widget.streamingProxyUrl} '
          'localPath=${widget.file.path}',
        );
      }
      // Open the file FIRST, then wire up streaming-specific listeners.
      //
      // Earlier this called `setupStreamingBufferingDebounce()` before
      // `openFile()`, with the intent of "not missing any initial buffering
      // events". In practice that order made `waitForFirstPlay` (called
      // from inside the debounce setup) capture a stale baseline from the
      // previous session's player state — so the grace period either
      // cleared too early or the spinner waited on an event that could
      // never fire. Setting up after open() is safe: the grace flag still
      // suppresses the spinner during initial decode.
      await playerService.openFile(
        widget.file,
        startPosition: widget.startPosition,
        isStreaming: widget.isStreaming,
        streamUrl: widget.streamingProxyUrl,
      );
      if (mounted) setState(() => _mediaOpened = true);
      if (widget.isStreaming) {
        setupStreamingBufferingDebounce();
        startPlaybackHealthMonitor();
      }

      // Auto-load a previously selected / sidecar subtitle. Best-effort —
      // any failure logs and falls through (user can still pick manually).
      unawaited(_autoLoadSubtitle());
    }

    _startHideControlsTimer();
  }

  /// Resolve a subtitle for the current file in this order:
  ///   1. Sidecar `.srt`/`.ass`/`.vtt`/etc. next to the video file, preferring
  ///      one whose filename contains the user's preferred-language tag.
  ///   2. Previously persisted OpenSubtitles selection for this file's
  ///      cache key (movie IMDB / series IMDB+S##E## / path hash).
  ///   3. Nothing — leave subtitle off.
  Future<void> _autoLoadSubtitle() async {
    try {
      final playerService = ref.read(playerServiceProvider);
      final scanner = ref.read(localMediaScannerProvider);
      final preferredLang = ref.read(preferredSubtitleLanguageProvider);

      final sidecars = await scanner.findSubtitles(widget.file.path);
      if (sidecars.isNotEmpty) {
        String chosen = sidecars.first;
        if (preferredLang != null && preferredLang.isNotEmpty) {
          final lang = preferredLang.toLowerCase();
          final byLang = sidecars.firstWhere(
            (p) => p.toLowerCase().contains('.$lang.'),
            orElse: () => sidecars.first,
          );
          chosen = byLang;
        }
        await playerService.loadExternalSubtitle(chosen);
        AppLog.d('[Subtitles] Auto-loaded sidecar: $chosen');
        return;
      }

      final cacheKey = computeSubtitleCacheKey(
        widget.file,
        movieImdbId: widget.movieImdbId,
        showImdbId: widget.showImdbId,
      );
      final saved = ref
          .read(currentExternalSubtitleProvider.notifier)
          .loadFor(cacheKey);
      if (saved != null && saved.url.isNotEmpty) {
        await playerService.loadExternalSubtitle(saved.url);
        ref.read(currentExternalSubtitleProvider.notifier).set(saved);
        AppLog.d(
          '[Subtitles] Auto-loaded persisted choice for $cacheKey '
          '(${saved.lang})',
        );
      }
    } catch (e) {
      AppLog.e('[Subtitles] Auto-load failed: $e');
    }
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _showControls = false);
      }
    });
  }

  @override
  void onUserInteraction() {
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
    // Capture the user's window size before going fullscreen so we
    // can restore it on exit (macOS otherwise resizes to default).
    if (newFullscreen) {
      try {
        _preFullscreenSize = await windowManager.getSize();
      } catch (_) {
        _preFullscreenSize = null;
      }
    }
    setState(() => _isFullscreen = newFullscreen);

    // On Windows, setFullScreen leaves WS_CAPTION on the window so the title
    // bar (with min/max/close) still shows. Hide it explicitly before going
    // fullscreen and restore it on exit.
    if (newFullscreen) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
    }
    await windowManager.setFullScreen(newFullscreen);
    if (!newFullscreen) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );
      // Restore pre-fullscreen size so the user's window doesn't snap
      // to the platform's default size.
      if (_preFullscreenSize != null) {
        await windowManager.setSize(_preFullscreenSize!);
      }
    }

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
      streamUrl: widget.streamingProxyUrl,
    );
    if (mounted) setState(() => _mediaOpened = true);
    if (widget.isStreaming) {
      setupStreamingBufferingDebounce();
      startPlaybackHealthMonitor();
    }
  }

  Future<void> _exitPlayer() async {
    if (_exiting) return;
    _exiting = true;
    try {
      if (_mediaOpened) {
        await ref.read(playerServiceProvider).stop();
      }
      if (_isFullscreen) {
        await windowManager.setFullScreen(false);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.normal,
          windowButtonVisibility: true,
        );
        final pre = _preFullscreenSize;
        if (pre != null) {
          await windowManager.setSize(pre);
        }
      }
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      AppLog.e('[Player] exit failed: $e');
      if (mounted) Navigator.of(context).pop();
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
    onUserInteraction();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_isSeeking || _dragStartPosition == null) return;

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

  /// Double-click anywhere on the picture toggles playback.
  ///
  /// This replaced a zoned gesture where the outer thirds skipped ±10 s and
  /// only the middle toggled — the zones were invisible, so which of three
  /// things a double-click did depended on where the pointer happened to be.
  /// Skipping stays on the ← / → keys and the bottom transport buttons, both
  /// of which still show the ripple.
  void _onDoubleTap() {
    ref.read(playerServiceProvider).playOrPause();
    onUserInteraction();
  }

  void _seekBackward() {
    _showSkipIndicator(forward: false);
    ref.read(playerServiceProvider).seekBackward(seconds: 10);
    onUserInteraction();
  }

  void _seekForward() {
    _showSkipIndicator(forward: true);
    ref.read(playerServiceProvider).seekForward(seconds: 10);
    onUserInteraction();
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

  // ── PlayerNextEpisodeController contract ─────────────────────────────

  @override
  LocalMediaFile get playingFile => widget.file;

  @override
  NextEpisodePlanner get planner => _planner;

  @override
  bool get resumePromptVisible => _showResumePrompt;

  @override
  String? get streamingTorrentHash => widget.streamingTorrentHash;

  @override
  int? get streamingFileIndex => widget.streamingFileIndex;

  @override
  String? get streamingProxyUrl => widget.streamingProxyUrl;

  @override
  void openReplacementPlayer(
    LocalMediaFile file, {
    String? torrentHash,
    int? fileIndex,
    String? proxyUrl,
    String? sessionId,
  }) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          file: file,
          isStreaming: torrentHash != null,
          streamingTorrentHash: torrentHash,
          streamingFileIndex: fileIndex,
          streamingProxyUrl: proxyUrl,
          streamingSessionId: sessionId,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _skipIndicatorTimer?.cancel();
    disposeNextEpisodeController();
    disposeStreamingHealth();
    _keyboardFocus.dispose();
    // Release the sessions this screen owns: cancelSession stops the 2 s
    // monitoring timer and shuts down the LocalStreamingServer. Uses the
    // notifier captured in initState, not ref.read — see below.
    for (final sessionId in {_ownedSessionId, prefetchSessionId}) {
      if (sessionId != null) {
        unawaited(_streamingSessions.cancelSession(sessionId));
      }
    }
    // Note: Don't use ref.read() in dispose - providers will clean up themselves.
    // Only call setFullScreen / setTitleBarStyle when we're actually in
    // fullscreen — otherwise the framework's own resize logic gets
    // triggered and the user's window size is reset to platform default.
    if (_isFullscreen) {
      windowManager.setFullScreen(false);
      windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );
      // Restore the size that was active before fullscreen, if known.
      final pre = _preFullscreenSize;
      if (pre != null) {
        windowManager.setSize(pre);
      }
    }
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
        ? (streamBuffering && !streamBufferingGrace)
        : rawBuffering;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _keyboardFocus,
        onKeyEvent: (node, event) {
          _handleKeyEvent(event, ref);
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: _showControls ? MouseCursor.defer : SystemMouseCursors.none,
          onHover: (_) => onUserInteraction(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Main video area with gesture detection
              GestureDetector(
                onTap: onUserInteraction,
                onDoubleTap: _onDoubleTap,
                onHorizontalDragStart: _onHorizontalDragStart,
                onHorizontalDragUpdate: _onHorizontalDragUpdate,
                onHorizontalDragEnd: _onHorizontalDragEnd,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_mediaOpened)
                      Video(
                        controller: videoController,
                        controls: NoVideoControls,
                      ),

                    // Buffering indicator — in streaming mode, surface the
                    // download progress so a long pause-for-cache shows the
                    // user the torrent is actually progressing.
                    if (isBuffering && _mediaOpened)
                      BufferingIndicator(
                        label: widget.isStreaming
                            ? bufferingLabel(streamingDownloadedRatio)
                            : null,
                      ),

                    // Skip backward indicator (left side)
                    if (_showSkipBackward)
                      Positioned(
                        left: 60,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: SkipRippleIndicator(forward: false),
                        ),
                      ),

                    // Skip forward indicator (right side)
                    if (_showSkipForward)
                      Positioned(
                        right: 60,
                        top: 0,
                        bottom: 0,
                        child: Center(
                          child: SkipRippleIndicator(forward: true),
                        ),
                      ),

                    // Seek indicator during drag
                    if (_isSeeking)
                      Center(
                        child: SeekIndicator(
                          seekDelta: _seekDelta,
                          dragStartTime: _dragStartTime!,
                        ),
                      ),

                    // Resume prompt overlay
                    if (_showResumePrompt)
                      ResumePrompt(
                        resumePosition: _resumePosition ?? Duration.zero,
                        onStartOver: () => _handleResume(false),
                        onResume: () => _handleResume(true),
                      ),

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
                            onSeekForward: _seekForward,
                            onSeekBackward: _seekBackward,
                            onToggleFullscreen: _toggleFullscreen,
                            onClose: _exitPlayer,
                            onShowShortcuts: _showShortcutsDialog,
                            streamingDownloadedRatio: widget.isStreaming
                                ? streamingDownloadedRatio
                                : null,
                            bufferedSpans: widget.isStreaming
                                ? bufferedSpans
                                : const [],
                            showId: currentShowId,
                            onContinueWatchingActivated:
                                onContinueWatchingActivated,
                            nextEpisodePrefetch: nextPrefetch,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // Up Next chip — sized to itself so player controls stay
              // tappable. Stays offered (expanded or minimized) after the
              // trigger percentage; Play/Stream consumes it.
              if (_planner.overlayActive &&
                  (nextEpisode != null || nextEpisodeFromTmdb != null))
                Positioned(
                  right: AppSpacing.lg,
                  bottom: 110,
                  child: NextEpisodeOverlay(
                    episodeCode:
                        nextEpisode?.episodeCode ??
                        nextEpisodeFromTmdb?.episodeCode ??
                        '',
                    title: nextEpisode != null
                        ? (nextEpisode!.showName ?? nextEpisode!.fileName)
                        : (nextEpisodeFromTmdb?.name ?? ''),
                    countdownSeconds: nextEpisode != null
                        ? ref.read(nextEpisodeCountdownSecondsProvider)
                        : null,
                    minimized: _planner.overlayMinimized,
                    playLabel: nextEpisode != null ? 'Play' : 'Stream',
                    onPlay: nextEpisode != null
                        ? onPlayNextEpisode
                        : onStreamNextEpisode,
                    onMinimize: minimizeNextEpisode,
                    onDismiss: consumeNextEpisodePrompt,
                    onRestore: restoreNextEpisode,
                  ),
                ),

              // Current-episode health-monitor chip (next-episode prefetch
              // is the spinner beside the Continue Watching pill).
              if (streamingStatus != null)
                Positioned(
                  top: MediaQuery.of(context).padding.top + AppSpacing.md,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: StreamingStatusIndicator(
                        status: streamingStatus!,
                        message: streamingMessage,
                        episodeCode: streamingEpisodeCode,
                        progress: streamingProgress,
                        onDismiss: dismissStreamingStatus,
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

  void _showShortcutsDialog() {
    showPlayerShortcutsDialog(context, onUserInteraction: onUserInteraction);
  }

  void _handleKeyEvent(KeyEvent event, WidgetRef ref) {
    handlePlayerKeyEvent(
      event,
      ref: ref,
      isFullscreen: _isFullscreen,
      onUserInteraction: onUserInteraction,
      onSeekBackward: _seekBackward,
      onSeekForward: _seekForward,
      onToggleFullscreen: _toggleFullscreen,
      onExitPlayer: _exitPlayer,
      onShowShortcuts: _showShortcutsDialog,
      mediaOpened: _mediaOpened,
      resumePromptVisible: _showResumePrompt,
    );
  }
}

// ---------------------------------------------------------------------------
// Buffering indicator — branded, frosted-glass feel
// ---------------------------------------------------------------------------
