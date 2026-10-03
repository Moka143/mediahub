import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../design/app_colors.dart';
import '../models/local_media_file.dart';
import '../models/playback_failure.dart';
import '../models/streaming_session.dart';
import '../providers/local_media_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/app_logger.dart';
import '../services/local_streaming_server.dart';
import '../services/next_episode_planner.dart';
import '../services/player_service.dart';
import '../widgets/next_episode_overlay.dart';
import '../widgets/player/player_error_overlay.dart';
import '../widgets/player/player_keyboard.dart';
import '../widgets/player/player_overlay_stack.dart';
import '../widgets/streaming_status_indicator.dart';
import '../widgets/video_controls.dart';
import '_player_next_episode_controller.dart';
import '_player_streaming_health.dart';
import '_player_window_chrome.dart';

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

  /// Info-hash of the torrent backing this stream, used by the
  /// PlaybackHealthMonitor to track download edge and prevent over-read into
  /// sparse (zero-filled) regions. Only meaningful when [isStreaming] is true.
  final String? streamingTorrentHash;

  /// Index of the target file within the torrent (matches the engine's file
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

  /// The player for [file], fed by [session] when it is a stream.
  ///
  /// The one place a [StreamingSession] becomes player arguments. Four call
  /// sites used to copy the six streaming fields by hand, and the copy in the
  /// next-episode hand-off had already dropped two of them.
  factory VideoPlayerScreen.fromSession({
    Key? key,
    required LocalMediaFile file,
    StreamingSession? session,
    String? showImdbId,
    String? movieImdbId,
    Duration? startPosition,
  }) => VideoPlayerScreen(
    key: key,
    file: file,
    startPosition: startPosition,
    showImdbId: showImdbId ?? session?.showImdbId,
    movieImdbId: movieImdbId ?? session?.movieImdbId,
    isStreaming: session != null,
    streamingTorrentHash: session?.torrentHash,
    streamingFileIndex: session?.selectedFileIndex,
    streamingProxyUrl: session?.streamUrl,
    initialBufferedRatio: session?.bufferProgress,
    streamingSessionId: session?.id,
  );

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen>
    with
        PlayerNextEpisodeController<VideoPlayerScreen>,
        PlayerStreamingHealth<VideoPlayerScreen>,
        PlayerWindowChrome<VideoPlayerScreen> {
  /// How long the controls stay up after the last pointer or key activity.
  static const Duration _controlsHideDelay = Duration(seconds: 3);

  /// How long the ±10 s ripple stays on screen.
  static const Duration _skipIndicatorDuration = Duration(milliseconds: 500);

  /// Drag-to-seek: seconds moved per pixel dragged (100 px = 10 s).
  static const double _dragSecondsPerPixel = 0.1;

  /// Saved progress below this fraction plays from the start without asking.
  static const double _resumePromptMinProgress = 0.05;

  bool _showControls = true;
  Timer? _hideControlsTimer;
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
  int _skipTick = 0;
  Timer? _skipIndicatorTimer;

  // Binge watching. The *when* — trigger window, overlay-vs-autoplay and
  // the one-shot guards — lives in [NextEpisodePlanner]; the *what* —
  // resolving the episode, the TMDB lookup, the prefetch and the hand-off —
  // lives in [PlayerNextEpisodeController]. This screen holds the planner
  // only because `build()` reads it to decide whether to draw the overlay.
  late final NextEpisodePlanner _planner;

  /// Captured in [initState] so [dispose] can reach them without `ref.read`,
  /// which is not safe there.
  late final StreamingSessionsNotifier _streamingSessions;
  late final PlayerService _playerService;

  /// The shared player's [PlayerService.generation] for the file this screen
  /// asked it to open; null until it has asked. What lets this screen stop
  /// playback it started — however it leaves — without stopping a file a
  /// newer screen has opened since.
  int? _openGeneration;

  StreamSubscription<PlaybackFailure>? _failureSubscription;

  /// Why this file could not be played, once mpv has given up on it.
  PlaybackFailure? _failure;

  /// Streaming sessions this screen must tear down on dispose. Set to null
  /// the moment a session is handed to a replacement screen — that screen
  /// takes ownership with it, and cancelling here would kill the proxy the
  /// next episode is about to read from.
  String? _ownedSessionId;

  @override
  void initState() {
    super.initState();
    _streamingSessions = ref.read(streamingSessionsProvider.notifier);
    _playerService = ref.read(playerServiceProvider);
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
      if (!mounted) return;
      _keyboardFocus.requestFocus();
      unawaited(_initializePlayer());
      unawaited(setupNextEpisodeWatcher());
      setupAutoDownloadWatcher();
      setupPlaybackCompletionWatcher();
    });
  }

  Future<void> _initializePlayer() async {
    _resetSubtitleState();
    _failureSubscription = _playerService.failures.listen(_onPlaybackFailure);

    // Check for existing progress
    final existingProgress = ref.read(
      fileWatchProgressProvider(widget.file.path),
    );

    if (existingProgress != null &&
        existingProgress.progress > _resumePromptMinProgress &&
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
      await _openMedia(startPosition: widget.startPosition);
    }

    if (mounted) _startHideControlsTimer();
  }

  /// Point the app-wide subtitle state at this file.
  ///
  /// The OpenSubtitles query and the selected external subtitle live in
  /// keep-alive providers, and nothing reset them between videos. A Library
  /// file — which opens with no IMDB id of its own — listed and loaded the
  /// previous movie's subtitles, saved choices under that movie's key, and
  /// showed its CC icon as on; pressing F re-applied the old track.
  void _resetSubtitleState() {
    final query = ref.read(subtitleContextProvider.notifier)..clear();
    ref.read(currentExternalSubtitleProvider.notifier).beginFile(widget.file);
    ref.read(sidecarSubtitlesProvider.notifier).set(const []);

    final movieImdbId = widget.movieImdbId;
    final showImdbId = widget.showImdbId;
    final season = widget.file.seasonNumber;
    final episode = widget.file.episodeNumber;
    if (movieImdbId != null) {
      query.setMovieContext(movieImdbId);
    } else if (showImdbId != null && season != null && episode != null) {
      query.setSeriesContext(
        imdbId: showImdbId,
        season: season,
        episode: episode,
      );
    }
  }

  /// Open the file, then wire up what depends on it being open.
  ///
  /// Open FIRST, then the streaming listeners. Setting up the buffering
  /// debounce before the open made `waitForFirstPlay` (called from inside
  /// it) capture a stale baseline from the previous session's player state —
  /// so the grace period either cleared too early or the spinner waited on
  /// an event that could never fire. After the open is safe: the grace flag
  /// still suppresses the spinner during initial decode.
  Future<void> _openMedia({Duration? startPosition}) async {
    final opening = _playerService.openFile(
      widget.file,
      startPosition: startPosition,
      isStreaming: widget.isStreaming,
      streamUrl: widget.streamingProxyUrl,
    );
    // `openFile` claims the shared player before its first await, so this is
    // the token for the file just requested.
    final generation = _playerService.generation;
    _openGeneration = generation;
    await opening;

    if (!mounted) {
      // Closed while the file was still opening — `openFile` can wait six
      // seconds for a duration before a resume seek. Nothing on screen would
      // stop what it went on to play, and for a stream the setup below would
      // reach `ref` on a disposed screen.
      await _playerService.stopIfCurrent(generation);
      return;
    }
    setState(() => _mediaOpened = true);
    if (widget.isStreaming) {
      setupStreamingBufferingDebounce();
      startPlaybackHealthMonitor();
    }

    // Auto-load a previously selected / sidecar subtitle. Best-effort —
    // any failure logs and falls through (user can still pick manually).
    unawaited(_autoLoadSubtitle());
  }

  void _onPlaybackFailure(PlaybackFailure failure) {
    if (!mounted || failure.generation != _openGeneration) return;
    setState(() {
      _failure = failure;
      _showControls = true;
    });
  }

  /// Resolve a subtitle for the current file in this order:
  ///   1. The choice saved for this file — the user picked it last time.
  ///   2. A sidecar `.srt`/`.ass`/`.vtt`/etc. next to the video file.
  ///   3. Nothing — leave subtitle off.
  ///
  /// Whatever loads is also recorded as the selection, so the picker shows
  /// it and fullscreen re-applies it. A sidecar used to load without being
  /// recorded, and was dropped by the first fullscreen toggle.
  Future<void> _autoLoadSubtitle() async {
    try {
      final scanner = ref.read(localMediaScannerProvider);
      final selection = ref.read(currentExternalSubtitleProvider.notifier);
      final sidecarList = ref.read(sidecarSubtitlesProvider.notifier);

      final paths = await scanner.findSubtitles(widget.file.path);
      if (!mounted) return;
      final sidecars = [for (final path in paths) sidecarSubtitle(path)];
      sidecarList.set(sidecars);

      final chosen =
          selection.savedForCurrentFile() ??
          (sidecars.isEmpty ? null : sidecars.first);
      if (chosen == null || chosen.url.isEmpty) return;

      await _playerService.loadExternalSubtitle(chosen.url);
      if (!mounted) return;
      selection.set(chosen);
      AppLog.d('[Subtitles] Auto-loaded ${chosen.langName ?? chosen.lang}');
    } catch (e) {
      AppLog.e('[Subtitles] Auto-load failed: $e');
    }
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(_controlsHideDelay, () {
      if (mounted && _failure == null) {
        setState(() => _showControls = false);
      }
    });
  }

  /// Bring the controls back and restart their hide timer.
  ///
  /// Runs on every mouse move, so it only rebuilds when the controls were
  /// actually hidden — it used to `setState` on each move, rebuilding the
  /// whole screen dozens of times a second while the pointer was moving.
  @override
  void onUserInteraction() {
    if (!mounted) return;
    if (!_showControls) setState(() => _showControls = true);
    _startHideControlsTimer();
  }

  Future<void> _handleResume(bool resume) async {
    setState(() => _showResumePrompt = false);
    await _openMedia(startPosition: resume ? _resumePosition : null);
  }

  /// Leave the player, stopping what it started.
  ///
  /// Always stops — not only once the media reported open. A file still
  /// opening when the user left used to be skipped here and never stopped:
  /// a local file played on with no screen in front of it.
  Future<void> _exitPlayer({PlayerExitReason? reason}) async {
    if (_exiting) return;
    _exiting = true;
    try {
      final generation = _openGeneration;
      if (generation != null) await _playerService.stopIfCurrent(generation);
      await exitWindowFullscreen();
    } catch (e) {
      AppLog.e('[Player] exit failed: $e');
    }
    if (mounted) Navigator.of(context).pop(reason);
  }

  // Handle horizontal swipe to seek
  void _onHorizontalDragStart(DragStartDetails details) {
    final player = ref.read(playerProvider);
    setState(() {
      _isSeeking = true;
      _seekDelta = 0;
      // Deltas only, so local vs global does not matter for correctness — but
      // it does for scale. UiScale can render the whole UI below 1.0, and
      // globalPosition is in untransformed root-view pixels, so a drag would
      // seek by the wrong amount. localPosition arrives already through the
      // transform.
      _dragStartPosition = details.localPosition;
      _dragStartTime = player.state.position;
    });
    onUserInteraction();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_isSeeking || _dragStartPosition == null) return;

    final dragDistance = details.localPosition.dx - _dragStartPosition!.dx;
    setState(() => _seekDelta = dragDistance * _dragSecondsPerPixel);
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_isSeeking || _dragStartTime == null) return;

    final newPosition = _dragStartTime! + Duration(seconds: _seekDelta.round());
    final clampedPosition = newPosition.isNegative
        ? Duration.zero
        : newPosition;

    unawaited(_playerService.seek(clampedPosition));

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
    unawaited(_playerService.playOrPause());
    onUserInteraction();
  }

  void _seekBackward() {
    _showSkipIndicator(forward: false);
    unawaited(_playerService.seekBackward());
    onUserInteraction();
  }

  void _seekForward() {
    _showSkipIndicator(forward: true);
    unawaited(_playerService.seekForward());
    onUserInteraction();
  }

  void _showSkipIndicator({required bool forward}) {
    _skipIndicatorTimer?.cancel();
    setState(() {
      _skipTick++;
      _showSkipForward = forward;
      _showSkipBackward = !forward;
    });
    _skipIndicatorTimer = Timer(_skipIndicatorDuration, () {
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
  String? get openedWithShowImdbId => widget.showImdbId;

  @override
  String? get streamingTorrentHash => widget.streamingTorrentHash;

  @override
  int? get streamingFileIndex => widget.streamingFileIndex;

  @override
  String? get streamingProxyUrl => widget.streamingProxyUrl;

  @override
  void openReplacementPlayer(
    LocalMediaFile file, {
    StreamingSession? session,
    String? showImdbId,
  }) {
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => VideoPlayerScreen.fromSession(
            file: file,
            session: session,
            showImdbId: showImdbId,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _skipIndicatorTimer?.cancel();
    unawaited(_failureSubscription?.cancel());
    disposeNextEpisodeController();
    disposeStreamingHealth();
    _keyboardFocus.dispose();
    // Stop what this screen started, if nothing newer owns the player — the
    // back button already did, but the route can also be removed under us
    // (a navigator pop, the app shell replacing it). Before the session
    // cancels below, so mpv is not left reading from a proxy that is gone.
    final generation = _openGeneration;
    if (generation != null) {
      unawaited(_playerService.stopIfCurrent(generation));
    }
    // Release the sessions this screen owns: cancelSession stops the 2 s
    // monitoring timer and shuts down the LocalStreamingServer. Uses the
    // notifier captured in initState, not ref.read, which is not safe here.
    for (final sessionId in {_ownedSessionId, prefetchSessionId}) {
      if (sessionId != null) {
        unawaited(_streamingSessions.cancelSession(sessionId));
      }
    }
    unawaited(exitWindowFullscreen());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = ref.watch(isPlayingProvider).value ?? false;
    final rawBuffering = ref.watch(isBufferingProvider).value ?? false;

    // When streaming, use the debounced buffering state (with grace period)
    // to avoid the indicator flickering every time mpv hits the download edge.
    final isBuffering = widget.isStreaming
        ? (streamBuffering && !streamBufferingGrace)
        : rawBuffering;

    final upNext = UpNextModel.resolve(
      overlayActive: _planner.overlayActive,
      downloaded: nextEpisode,
      fromTmdb: nextEpisodeFromTmdb,
      countdownSeconds: ref.read(nextEpisodeCountdownSecondsProvider),
    );
    // Esc dismisses the card while it is expanded, rather than closing the
    // player out from under it.
    final dismissUpNext = upNext != null && !_planner.overlayMinimized
        ? consumeNextEpisodePrompt
        : null;
    final failure = _failure;
    final statusMessage = streamingStatusMessage;

    return Scaffold(
      backgroundColor: AppColors.mediaBlack,
      body: Focus(
        focusNode: _keyboardFocus,
        onKeyEvent: (node, event) =>
            handlePlayerKeyEvent(
              event,
              ref: ref,
              isFullscreen: isWindowFullscreen,
              onUserInteraction: onUserInteraction,
              onSeekBackward: _seekBackward,
              onSeekForward: _seekForward,
              onToggleFullscreen: () => unawaited(toggleWindowFullscreen()),
              onExitPlayer: () => unawaited(_exitPlayer()),
              onShowShortcuts: _showShortcutsDialog,
              onDismissUpNext: dismissUpNext,
              mediaOpened: _mediaOpened && failure == null,
              resumePromptVisible: _showResumePrompt,
            )
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
        child: MouseRegion(
          cursor: _showControls ? MouseCursor.defer : SystemMouseCursors.none,
          onHover: (_) => onUserInteraction(),
          child: PlayerOverlayStack(
            video: _mediaOpened
                ? Video(
                    controller: ref.watch(videoControllerProvider),
                    controls: NoVideoControls,
                  )
                : null,
            showBuffering: isBuffering,
            bufferingLabel: widget.isStreaming
                ? bufferingLabel(streamingDownloadedRatio)
                : null,
            showSkipForward: _showSkipForward,
            showSkipBackward: _showSkipBackward,
            skipTick: _skipTick,
            seekDelta: _isSeeking ? _seekDelta : null,
            seekStartTime: _isSeeking ? _dragStartTime : null,
            showResumePrompt: _showResumePrompt,
            resumePosition: _resumePosition ?? Duration.zero,
            onStartOver: () => unawaited(_handleResume(false)),
            onResume: () => unawaited(_handleResume(true)),
            controlsVisible: _showControls,
            controls: VideoControlsOverlay(
              file: widget.file,
              isPlaying: isPlaying,
              isFullscreen: isWindowFullscreen,
              onPlayPause: () => unawaited(_playerService.playOrPause()),
              onSeekForward: _seekForward,
              onSeekBackward: _seekBackward,
              onToggleFullscreen: () => unawaited(toggleWindowFullscreen()),
              onClose: () => unawaited(_exitPlayer()),
              onShowShortcuts: _showShortcutsDialog,
              streamingDownloadedRatio: widget.isStreaming
                  ? streamingDownloadedRatio
                  : null,
              bufferedSpans: widget.isStreaming ? bufferedSpans : const [],
              showId: currentShowId,
              onContinueWatchingActivated: onContinueWatchingActivated,
              nextEpisodePrefetch: nextPrefetch,
            ),
            upNextChip: upNext == null
                ? null
                : NextEpisodeOverlay(
                    episodeCode: upNext.episodeCode,
                    title: upNext.title,
                    countdownSeconds: upNext.countdownSeconds,
                    minimized: _planner.overlayMinimized,
                    playLabel: upNext.playLabel,
                    onPlay: upNext.playsFromDisk
                        ? () => unawaited(onPlayNextEpisode())
                        : () => unawaited(onStreamNextEpisode()),
                    onMinimize: minimizeNextEpisode,
                    onDismiss: consumeNextEpisodePrompt,
                    onRestore: restoreNextEpisode,
                  ),
            statusChip: statusMessage == null
                ? null
                : StreamingStatusIndicator(
                    message: statusMessage,
                    progress: streamingStatusProgress,
                  ),
            error: failure == null
                ? null
                : PlayerErrorOverlay(
                    message: playbackFailureMessage(
                      failure,
                      streaming: widget.isStreaming,
                    ),
                    onBack: () => unawaited(_exitPlayer()),
                    onTryAnotherSource: widget.isStreaming
                        ? () => unawaited(
                            _exitPlayer(
                              reason: PlayerExitReason.tryAnotherSource,
                            ),
                          )
                        : null,
                  ),
            onTap: onUserInteraction,
            onDoubleTap: _onDoubleTap,
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
          ),
        ),
      ),
    );
  }

  void _showShortcutsDialog() {
    showPlayerShortcutsDialog(context, onUserInteraction: onUserInteraction);
  }
}
