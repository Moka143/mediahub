import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../models/eztv_torrent.dart';
import '../models/local_media_file.dart';
import '../models/torrent_file.dart';
import '../providers/auto_download_provider.dart' hide nextEpisodeProvider;
import '../providers/connection_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/streaming_provider.dart';
import '../services/auto_download_service.dart';
import '../services/local_streaming_server.dart';
import '../services/streaming_service.dart';
import '../widgets/next_episode_overlay.dart';
import '../widgets/shortcuts_help_dialog.dart';
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
  });

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
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

  /// One-shot guard for the "Continue Watching ON → seamless auto-play"
  /// path. When the user explicitly opted in for this show we skip the
  /// next-episode overlay and just hand off to `_onPlayNextEpisode` once
  /// playback enters the trigger window AND the next episode is ready.
  bool _autoNextEpisodeFired = false;
  bool _nextEpisodeDownloadStarted =
      false; // Track if we started downloading next ep
  Episode? _downloadingEpisode; // The episode we're downloading
  String? _nextEpisodeStreamingTorrentHash;
  int? _nextEpisodeStreamingFileIndex;

  /// HTTP proxy URL for the next-episode stream, when one has been set up.
  /// Mirrors `widget.streamingProxyUrl` for the current episode but for the
  /// auto-next-episode handoff in [_onPlayNextEpisode]. Without this the
  /// new VideoPlayerScreen would open in direct-disk mode and the seek-bar
  /// buffered region wouldn't update.
  String? _nextEpisodeStreamingProxyUrl;
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

  // Playback health monitor — only active during streaming.
  // Watches the player position vs. download edge and intervenes:
  //   • Pre-emptively pauses when playback approaches the download edge
  //     (so mpv doesn't read into sparse/zero regions and freeze).
  //   • Detects stalls (position frozen while supposedly playing) and
  //     recovers via pause + back-seek + resume to flush mpv's demuxer.
  Timer? _healthMonitorTimer;
  StreamSubscription<Duration>? _healthPositionSub;
  Duration _lastObservedPosition = Duration.zero;
  DateTime _lastPositionAdvanceAt = DateTime.now();
  bool _autoBufferPaused = false;
  bool _recoveryInFlight = false;
  bool _healthCheckInFlight = false;

  /// Set true the first time mpv's position actually advances past zero.
  /// Gates stall detection so we don't trigger the recovery seek during
  /// the initial open window where position is legitimately frozen at 0
  /// while mpv loads the file over the HTTP proxy.
  bool _hasStartedPlayback = false;

  /// Last time the recovery seek ran — rate-limits subsequent recoveries
  /// so mpv has time to actually settle before we intervene again.
  DateTime _lastRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Latest 0.0–1.0 download progress for the streaming target file.
  // Drives the seek-bar's buffered-track in streaming mode.
  double? _streamingDownloadedRatio;

  /// True while the proxy-mode seek-past-head indicator is on screen, so we
  /// know to dismiss it once the buffer catches up.
  bool _seekPastHeadActive = false;

  /// We disable qBittorrent's sequential-download mode the first time the
  /// user seeks past the download edge — sequential mode means "always pull
  /// pieces from the front", which would force the user to wait for the
  /// entire intermediate region to download before the seek target arrives.
  /// With sequential off, qBittorrent's piece picker can pull pieces around
  /// the seek target from any peer; combined with the piece-aware proxy,
  /// playback resumes from the new position once those pieces land.
  ///
  /// One-shot per session: once flipped off, we leave it off for the rest
  /// of the player screen's lifetime. The next episode starts on its own
  /// torrent with fresh sequential=true (set by StreamingService.addTorrent),
  /// and a fresh VideoPlayerScreen with this flag back at false.
  bool _sequentialDisabledForSeek = false;

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

    if (existingProgress != null &&
        existingProgress.progress > 0.05 &&
        existingProgress.progress < 0.95 &&
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
        debugPrint(
          '[VideoPlayerScreen] opening streaming hash=${widget.streamingTorrentHash} '
          'fileIdx=${widget.streamingFileIndex} '
          'proxyUrl=${widget.streamingProxyUrl} '
          'localPath=${widget.file.path}',
        );
      }
      // Open the file FIRST, then wire up streaming-specific listeners.
      //
      // Earlier this called `_setupStreamingBufferingDebounce()` before
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
      if (widget.isStreaming) {
        _setupStreamingBufferingDebounce();
        _startPlaybackHealthMonitor();
      }
    }

    _startHideControlsTimer();
  }

  static const _bufferingShowDelay = Duration(milliseconds: 400);
  static const _bufferingHideDelay = Duration(seconds: 1);
  // Keep this in sync with PlayerService.waitForFirstPlay's default — both
  // values gate the same "still loading?" deadline.
  static const _firstPlayTimeout = Duration(seconds: 7);
  static const _postPlayGrace = Duration(milliseconds: 500);

  // PlaybackHealthMonitor tunables.
  static const _healthPollInterval = Duration(seconds: 2);
  // Pause when fewer than this many seconds of *download* are buffered ahead
  // of the player position.
  static const _pauseBelowSecondsAhead = 8.0;
  // Resume only after the buffer ahead has grown to this much — prevents
  // immediate re-pause flapping at the boundary.
  static const _resumeAboveSecondsAhead = 25.0;
  // Stall detector: position frozen for at least this long while playing
  // triggers the pause+back-seek+resume recovery. We were originally at 4s
  // but bumped to 15s after observing two real cases where the recovery
  // kept firing every cycle and prevented mpv from finishing what it was
  // already doing:
  //   • initial open of HEVC 1080p over the HTTP proxy can take 5–10s
  //     while mpv probes + primes the decoder;
  //   • a forward seek to a buffered position similarly needs several
  //     seconds for mpv to re-key the decoder.
  // 15s is well past both legitimate cases but still catches a real freeze.
  static const _stallThreshold = Duration(seconds: 15);
  // Minimum gap between successive stall recoveries. Without this we'd
  // re-trigger every poll interval after the previous recovery completed,
  // hammering mpv with seeks. mpv may need multiple seconds to settle
  // after a recovery seek before its position starts advancing again.
  static const _minRecoveryGap = Duration(seconds: 12);
  // How far back to seek when recovering from a stall — far enough that mpv
  // re-reads from a region that's definitely already on disk.
  static const _stallBackSeek = Duration(seconds: 3);

  /// Start monitoring the player vs. the torrent's download edge.
  ///
  /// Two jobs:
  /// 1. **Edge tracking** — pause player when close to download edge so mpv
  ///    doesn't read into sparse/zero regions. Resume when buffer recovers.
  /// 2. **Stall recovery** — if the player position stops advancing while
  ///    supposedly playing (mpv hit zeros and froze its video decoder),
  ///    pause + small back-seek + resume to flush the demuxer.
  void _startPlaybackHealthMonitor() {
    if (widget.streamingTorrentHash == null) {
      // Without a hash we can't query torrent state — only the stall detector
      // is useful, but it'd fire on legitimate user pauses too. Skip.
      return;
    }

    _healthMonitorTimer?.cancel();
    _healthPositionSub?.cancel();

    _lastObservedPosition = Duration.zero;
    _lastPositionAdvanceAt = DateTime.now();
    _hasStartedPlayback = false;
    _lastRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);

    final player = ref.read(playerProvider);

    // Track when the player position last moved (stall detection input).
    _healthPositionSub = player.stream.position.listen((pos) {
      final delta = (pos - _lastObservedPosition).inMilliseconds.abs();
      if (delta > 250) {
        _lastObservedPosition = pos;
        _lastPositionAdvanceAt = DateTime.now();
        // First real frame delivered — from now on, a frozen position is
        // a real stall worth recovering from. Before this, position is at
        // 0 because mpv is still loading; recovering would just hammer it.
        if (pos > Duration.zero) {
          _hasStartedPlayback = true;
        }
      }
    });

    _healthMonitorTimer = Timer.periodic(_healthPollInterval, (_) {
      _runHealthCheck();
    });
    // Fire once immediately so the seek-bar's buffered region populates
    // without waiting for the first poll interval.
    _runHealthCheck();
  }

  Future<void> _runHealthCheck() async {
    if (!mounted || _recoveryInFlight || _healthCheckInFlight) return;
    _healthCheckInFlight = true;
    try {
      await _runHealthCheckInner();
    } finally {
      _healthCheckInFlight = false;
    }
  }

  Future<void> _runHealthCheckInner() async {
    final hash = widget.streamingTorrentHash;
    final fileIdx = widget.streamingFileIndex;
    if (hash == null) return;

    final player = ref.read(playerProvider);
    final isPlaying = player.state.playing;
    final position = player.state.position;
    final duration = player.state.duration;
    if (duration.inMilliseconds <= 0) return;

    // 1) Stall detection — only meaningful while we believe we're playing
    // and we haven't already paused the player ourselves for buffering.
    //
    // The recovery seek (pause + back-seek + play) was designed for the
    // old direct-disk path, where mpv could get its decoder wedged on
    // sparse zero data and needed an external nudge to flush its demuxer.
    // With the LocalStreamingServer proxy that scenario can't happen any
    // more: mpv only ever reads bytes the proxy actually hands it, the
    // network cache pauses-for-cache cleanly when we throttle the
    // response, and resumes the moment data flows. Triggering a recovery
    // seek during a normal cache pause actively breaks playback (the
    // seek invalidates mpv's decode pipeline mid-prime, the next stall
    // fires 15s later, ad infinitum — the loop you saw in logs).
    //
    // So: skip stall recovery entirely in proxy mode. Keep the
    // diagnostic so we can see if something else gets wedged, but don't
    // act on it.
    final usingProxyForStall = widget.streamingProxyUrl != null;
    if (_hasStartedPlayback &&
        isPlaying &&
        !_autoBufferPaused &&
        !usingProxyForStall) {
      final now = DateTime.now();
      final timeSinceAdvance = now.difference(_lastPositionAdvanceAt);
      final timeSinceRecovery = now.difference(_lastRecoveryAt);
      if (timeSinceAdvance >= _stallThreshold &&
          timeSinceRecovery >= _minRecoveryGap) {
        debugPrint(
          '[HealthMonitor] Stall detected — position frozen for '
          '${timeSinceAdvance.inSeconds}s. Recovering.',
        );
        _lastRecoveryAt = now;
        await _recoverFromStall();
        return;
      }
    }

    // 2) Edge tracking — pause/resume based on how far ahead we have data.
    try {
      final qbt = ref.read(qbApiServiceProvider);
      final files = await qbt.getTorrentFiles(hash);
      if (fileIdx == null || fileIdx < 0 || fileIdx >= files.length) {
        return;
      }

      final file = files[fileIdx];
      final fileSize = file.size;
      final fileProgress = file.progress;
      if (fileSize <= 0) return;

      // Push the latest download progress into the seek-bar's buffered track.
      if (mounted &&
          (_streamingDownloadedRatio == null ||
              (fileProgress - _streamingDownloadedRatio!).abs() > 0.001)) {
        setState(() => _streamingDownloadedRatio = fileProgress);
      }

      // Special case: file fully (or nearly) downloaded — disable edge
      // tracking entirely. Nothing useful to pause for.
      if (fileProgress >= 0.995) {
        if (_autoBufferPaused) {
          _autoBufferPaused = false;
          await player.play();
        }
        if (_seekPastHeadActive) {
          _seekPastHeadActive = false;
          _dismissStreamingStatus();
        }
        return;
      }

      // When streaming via the LocalStreamingServer proxy, the proxy + mpv's
      // network cache handle buffering by themselves: pauses-for-cache when
      // we throttle the response, resumes when bytes flow. The pause/resume
      // side-effects below were designed for the old direct-disk path and
      // fight mpv in proxy mode (especially because we disable the MKV tail
      // probe, which makes `duration` unreliable and breaks the `secondsAhead`
      // formula).
      //
      // The one thing the proxy can't do for us is *tell the user why* they
      // see a spinner after seeking past the download head — the proxy just
      // serves bytes slowly. We surface that here.
      final usingProxy = widget.streamingProxyUrl != null;
      if (usingProxy) {
        _updateSeekPastHeadIndicator(
          position: position,
          duration: duration,
          fileProgress: fileProgress,
        );
        return;
      }

      // Non-proxy fallback (old direct-disk path). Approximate where playback
      // is in bytes — uniform-bitrate assumption is good enough for the
      // 8s/25s hysteresis band.
      final ratio = position.inMilliseconds / duration.inMilliseconds;
      final bytesAtPosition = (fileSize * ratio).round();
      final bytesAvailable = (fileSize * fileProgress).round();
      final bytesAhead = bytesAvailable - bytesAtPosition;

      final avgBytesPerSecond = fileSize / duration.inSeconds;
      final secondsAhead = avgBytesPerSecond > 0
          ? bytesAhead / avgBytesPerSecond
          : 0.0;

      if (!_autoBufferPaused &&
          isPlaying &&
          secondsAhead < _pauseBelowSecondsAhead) {
        debugPrint(
          '[HealthMonitor] Pre-empt pause — only '
          '${secondsAhead.toStringAsFixed(1)}s buffered ahead.',
        );
        _autoBufferPaused = true;
        await player.pause();
        _showStreamingStatus(
          status: StreamingStatus.buffering,
          message: 'Buffering — waiting for download…',
          progress: fileProgress,
        );
      } else if (_autoBufferPaused &&
          secondsAhead >= _resumeAboveSecondsAhead) {
        debugPrint(
          '[HealthMonitor] Resume — '
          '${secondsAhead.toStringAsFixed(1)}s buffered ahead.',
        );
        _autoBufferPaused = false;
        _dismissStreamingStatus();
        // Reset the stall timer so the position-advance check doesn't fire
        // immediately after resume (it takes mpv a moment to start ticking).
        _lastPositionAdvanceAt = DateTime.now();
        await player.play();
      } else if (_autoBufferPaused) {
        // While paused, keep the indicator updated with progress so the user
        // sees movement instead of a stuck "Buffering" forever.
        final secs = secondsAhead.clamp(0.0, _resumeAboveSecondsAhead).round();
        _showStreamingStatus(
          status: StreamingStatus.buffering,
          message:
              'Buffering — $secs/${_resumeAboveSecondsAhead.round()}s ahead',
          progress: fileProgress,
        );
      }
    } catch (e) {
      debugPrint('[HealthMonitor] Health check error: $e');
    }
  }

  /// In proxy mode, detect when playback position is past the download edge
  /// (typically caused by a user seek into the unbuffered region) and:
  ///
  ///   1. Disable sequential download on the torrent the first time it
  ///      happens, so qBittorrent's piece picker can fetch pieces around
  ///      the seek target instead of grinding sequentially from the head.
  ///   2. Surface an overlay so the user knows what's happening — the
  ///      proxy will serve bytes as qBittorrent writes them, but without
  ///      this signal it just looks like a generic spinner.
  ///
  /// The overlay is dismissed when the buffer catches up past the playback
  /// position. The sequential-mode toggle is one-shot per screen lifetime.
  void _updateSeekPastHeadIndicator({
    required Duration position,
    required Duration duration,
    required double fileProgress,
  }) {
    // Need a plausible duration to compare ratios. mpv occasionally reports
    // a near-zero duration during initial open before the demuxer settles —
    // skip until that lands. Same guard kept the non-proxy `secondsAhead`
    // calc out of the wildly-negative regime in earlier rounds.
    if (duration.inSeconds < 30) return;

    final positionRatio = position.inMilliseconds / duration.inMilliseconds;
    // 1% slack absorbs VBR jitter so a few seconds of play near the edge
    // doesn't toggle the indicator on and off.
    const slack = 0.01;
    final pastHead = positionRatio > fileProgress + slack;

    if (pastHead) {
      _seekPastHeadActive = true;
      if (!_sequentialDisabledForSeek) {
        _sequentialDisabledForSeek = true;
        unawaited(_disableSequentialForSeek());
      }
      _showStreamingStatus(
        status: StreamingStatus.buffering,
        message: 'Fetching pieces around new position…',
        progress: fileProgress,
      );
    } else if (_seekPastHeadActive) {
      _seekPastHeadActive = false;
      _dismissStreamingStatus();
    }
  }

  /// Flip sequential-download off for the streaming torrent so qBittorrent
  /// can pull pieces around the seek target instead of grinding from the
  /// head. Idempotent at the API level — we check the current state before
  /// toggling so back-to-back calls don't oscillate it.
  Future<void> _disableSequentialForSeek() async {
    final hash = widget.streamingTorrentHash;
    if (hash == null) return;
    try {
      final qbt = ref.read(qbApiServiceProvider);
      final torrents = await qbt.getTorrents(hashes: [hash]);
      if (torrents.isEmpty) return;
      if (!torrents.first.sequentialDownload) {
        debugPrint(
          '[HealthMonitor] sequential already off for $hash — leaving alone',
        );
        return;
      }
      final ok = await qbt.toggleSequentialDownload(hash);
      debugPrint(
        '[HealthMonitor] sequential download toggled off for seek '
        '(hash=$hash, success=$ok)',
      );
    } catch (e) {
      debugPrint('[HealthMonitor] failed to toggle sequential off: $e');
    }
  }

  Future<void> _recoverFromStall() async {
    _recoveryInFlight = true;
    try {
      final player = ref.read(playerProvider);
      final pos = player.state.position;

      // Pause first so mpv stops trying to decode garbage.
      await player.pause();

      // Force mpv to flush its demuxer cache and re-read fresh data. When
      // we're already a few seconds in, a back-seek into known-good
      // (already played) territory works. Near the start of the file
      // (the typical "opens but never plays" case) seeking *back* to 0
      // when we're already at 0 is a no-op for mpv — instead probe
      // forward by 1 s, then return to the original position. Either
      // path forces a demuxer flush and clears `paused-for-cache`.
      Duration resumeFrom;
      if (pos < _stallBackSeek) {
        await player.seek(pos + const Duration(seconds: 1));
        await Future.delayed(const Duration(milliseconds: 300));
        await player.seek(pos);
        resumeFrom = pos;
      } else {
        final target = pos - _stallBackSeek;
        final clamped = target.isNegative ? Duration.zero : target;
        await player.seek(clamped);
        resumeFrom = clamped;
      }

      // Give mpv a moment to re-prime the demuxer before resuming.
      await Future.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;

      _lastObservedPosition = resumeFrom;
      _lastPositionAdvanceAt = DateTime.now();
      await player.play();
    } catch (e) {
      debugPrint('[HealthMonitor] Stall recovery failed: $e');
    } finally {
      _recoveryInFlight = false;
    }
  }

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
      // Always (re)schedule a transition based on the latest signal. Without
      // this, a sequence of buffering=true→false→true→false at the download
      // edge could leave us with `_streamBuffering=true` permanently: the
      // hide-timer scheduled on the false event gets cancelled by the next
      // true event but no fresh hide-timer is set when buffering eventually
      // settles to false (because `_streamBuffering` is already true so the
      // first branch's guard `&& !_streamBuffering` was false).
      _bufferingDebounceTimer?.cancel();

      if (isBuffering) {
        if (_streamBuffering) return;
        _bufferingDebounceTimer = Timer(_bufferingShowDelay, () {
          if (mounted) setState(() => _streamBuffering = true);
        });
      } else {
        if (!_streamBuffering) return;
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

    // Attach the position listener UP FRONT — even before we know whether
    // there's a next episode. If we wait until TMDB / local scan resolves
    // (a network round trip + filesystem scan, which can outlast the user
    // crossing the countdown threshold) we miss the show window entirely.
    // The auto-download flow can also surface a next episode much later
    // (after buffering completes), and we want the overlay to fire then
    // too. So: always-attach, lazy-check `_hasNextEpisode()` on each tick.
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted || _showResumePrompt) return;

      final duration = player.state.duration;
      if (duration.inSeconds <= 0) return;

      final countdownSeconds = ref.read(nextEpisodeCountdownSecondsProvider);
      final remaining = duration - position;

      // Trigger when EITHER:
      //   • playback is in the final 10% of the episode (scales with
      //     duration — ~4 min on a 45-min ep, ~6 min on an hour-long ep,
      //     covers the credits window where users want the prompt), OR
      //   • there's less than `countdownSeconds` left (fallback for very
      //     short content where 10% is only seconds)
      // Whichever is reached first. `remaining > 0` excludes content that
      // has already ended — the playback-completion watcher handles that.
      final positionRatio = position.inMilliseconds / duration.inMilliseconds;
      final inFinalTenth = positionRatio >= 0.90;
      final withinCountdown = remaining.inSeconds <= countdownSeconds;
      final inTriggerWindow =
          (inFinalTenth || withinCountdown) && remaining.inSeconds > 0;

      if (!inTriggerWindow) return;

      // When the user explicitly opted into Continue Watching for this
      // show, skip the countdown overlay entirely and just hand off to
      // the next episode the moment its proxy is ready. Mirrors how
      // streaming services play the next ep without asking — the
      // explicit toggle IS the consent.
      final cwOverride = _currentShowId == null
          ? null
          : ref
                .read(autoDownloadProvider)
                .showAutoDownloadOverrides[_currentShowId];
      final continueWatchingOn = cwOverride == true;
      if (continueWatchingOn) {
        if (!_autoNextEpisodeFired && _nextEpisode != null) {
          _autoNextEpisodeFired = true;
          debugPrint(
            '[ContinueWatching] auto-playing next episode '
            '(showId=$_currentShowId, position=${position.inSeconds}s)',
          );
          _onPlayNextEpisode();
        }
        return;
      }

      // Default flow: show the overlay if a next episode is known.
      if (_nextEpisodeOverlayDismissed || _showNextEpisodeOverlay) return;
      if (!_hasNextEpisode()) return;

      setState(() {
        _showNextEpisodeOverlay = true;
      });
    });

    // Resolve next-episode info in the background — TMDB is authoritative
    // (so we don't skip episodes) but slow, so checking this *after*
    // attaching the listener avoids the early-exit race.
    await _checkTmdbForNextEpisode();

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
          debugPrint(
            '[NextEpisode] Found downloaded next episode: ${downloadedNextEp.fileName}',
          );
          if (mounted) {
            setState(() {
              _nextEpisode = downloadedNextEp;
              _nextEpisodeFromTmdb = null;
            });
          }
        } else {
          debugPrint(
            '[NextEpisode] Next episode S${_nextEpisodeFromTmdb!.seasonNumber}E${_nextEpisodeFromTmdb!.episodeNumber} not downloaded - will offer download',
          );
        }
      }
    } else {
      // TMDB didn't find next episode (network failure, no TMDB match).
      // Fall back to local-only check.
      final localNext = ref.read(nextEpisodeProvider(widget.file));
      if (localNext != null && mounted) {
        setState(() => _nextEpisode = localNext);
      }
    }
  }

  bool _hasNextEpisode() =>
      _nextEpisode != null || _nextEpisodeFromTmdb != null;

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
      // setState rather than bare assign — VideoControlsOverlay reads
      // `_currentShowId` to decide whether to render the per-show
      // Continue Watching toggle. Without the rebuild signal the pill
      // wouldn't appear until some other state change triggered build().
      if (mounted) {
        setState(() => _currentShowId = show.id);
      } else {
        _currentShowId = show.id;
      }

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

  /// Called when the user flips Continue Watching to explicit-On for this
  /// show. Kicks the next-episode auto-download off **immediately** instead
  /// of waiting for the progress threshold. Idempotent: the existing
  /// `_autoDownloadTriggered` one-shot guard means a no-op if a download
  /// is already in flight.
  void _onContinueWatchingActivated() {
    if (_autoDownloadTriggered) {
      debugPrint(
        '[ContinueWatching] activated — auto-download already in flight, '
        'no kickstart needed',
      );
      return;
    }
    debugPrint(
      '[ContinueWatching] activated — kicking off auto-download immediately',
    );
    _autoDownloadTriggered = true;
    _triggerAutoDownload();
  }

  void _setupAutoDownloadWatcher() {
    final player = ref.read(playerProvider);
    final state = ref.read(autoDownloadProvider);
    final notifier = ref.read(autoDownloadProvider.notifier);

    debugPrint(
      '[AutoDownload] Attached watcher: '
      'global.enabled=${state.enabled} '
      'global.downloadOnProgress=${state.downloadOnProgress} '
      'overrides=${state.showAutoDownloadOverrides} '
      'threshold=${state.progressThreshold} '
      'active(now)=${notifier.isAutoDownloadActiveForShow(_currentShowId)} '
      'showId=$_currentShowId',
    );

    // Throttle the per-tick "we crossed threshold but gate is closed" log so
    // we don't spam every position event.
    var lastDecisionLogAt = DateTime.fromMillisecondsSinceEpoch(0);

    _autoDownloadSubscription = player.stream.position.listen((position) {
      if (!mounted || _autoDownloadTriggered) return;

      // Re-resolve every tick so toggling the per-show pill (or the global
      // setting) takes effect without restarting playback.
      final state = ref.read(autoDownloadProvider);
      final notifier = ref.read(autoDownloadProvider.notifier);
      final active = notifier.isAutoDownloadActiveForShow(_currentShowId);

      final duration = player.state.duration;
      if (duration.inSeconds <= 0) return;

      final progress = position.inMilliseconds / duration.inMilliseconds;
      final threshold = state.progressThreshold;

      if (!active) {
        if (progress >= threshold) {
          final now = DateTime.now();
          if (now.difference(lastDecisionLogAt).inSeconds >= 5) {
            lastDecisionLogAt = now;
            debugPrint(
              '[AutoDownload] At ${(progress * 100).toStringAsFixed(1)}% '
              'but gate is closed: enabled=${state.enabled} '
              'overrideForShow=${_currentShowId == null ? "<no-show>" : state.showAutoDownloadOverrides[_currentShowId]} '
              'downloadOnProgress=${state.downloadOnProgress}',
            );
          }
        }
        return;
      }

      if (progress >= threshold) {
        debugPrint(
          '[AutoDownload] Crossed threshold ($threshold) at '
          '${(progress * 100).toStringAsFixed(1)}% — triggering download',
        );
        _autoDownloadTriggered = true;
        _triggerAutoDownload();
      }
    });
  }

  Future<void> _triggerAutoDownload() async {
    final file = widget.file;

    final showName = file.showName;
    final season = file.seasonNumber;
    final episode = file.episodeNumber;
    final quality = file.quality ?? '1080p';

    if (showName == null || season == null || episode == null) return;

    try {
      // Prefer the show id + imdb id we already resolved in
      // `_checkTmdbForNextEpisode` (which uses `getShowDetailsWithImdb`).
      // Falling back to a fresh search-then-details pair would also work,
      // but the older path used `getShowDetails` which doesn't request
      // external IDs and so always returned a null imdb id — auto-download
      // bailed out one step later because the torrent search needs imdb.
      var showId = _currentShowId;
      var imdbId = _currentImdbId;

      if (showId == null || imdbId == null) {
        final tmdbService = ref.read(tmdbServiceProvider);
        final shows = await tmdbService.searchShows(showName);
        if (shows.isEmpty) {
          debugPrint(
            '[AutoDownload] _triggerAutoDownload: TMDB returned no shows for $showName',
          );
          return;
        }
        final show = shows.first;
        final details = await tmdbService.getShowDetailsWithImdb(show.id);
        showId = show.id;
        imdbId = details.imdbId;
        if (mounted) {
          setState(() {
            _currentShowId = showId;
            _currentImdbId = imdbId;
          });
        }
      }

      // When the user has explicitly opted into Continue Watching for this
      // show, route through `_onStreamNextEpisode` instead of the provider's
      // disk-only path. That's the same flow the manual "Stream Next" button
      // uses — it both downloads AND wires up `_nextEpisodeStreamingTorrentHash`
      // / `_nextEpisodeStreamingProxyUrl` via `_monitorNextEpisodeStream`, so
      // the seamless next-episode hand-off opens with the seek-bar buffered
      // indicator and HealthMonitor live. The provider path doesn't do that
      // (it's for "download to disk for later" semantics) and would leave the
      // user watching ep N+1 without any streaming UI.
      final state = ref.read(autoDownloadProvider);
      final cwOverride = state.showAutoDownloadOverrides[showId];
      if (cwOverride == true && _nextEpisodeFromTmdb != null) {
        debugPrint(
          '[AutoDownload] _triggerAutoDownload → _onStreamNextEpisode '
          '(CW on for show $showId)',
        );
        await _onStreamNextEpisode();
        return;
      }

      debugPrint(
        '[AutoDownload] _triggerAutoDownload → onWatchProgress '
        'showId=$showId imdbId=$imdbId',
      );

      ref
          .read(autoDownloadProvider.notifier)
          .onWatchProgress(
            showId: showId,
            imdbId: imdbId,
            showName: showName,
            season: season,
            episode: episode,
            progress: state.progressThreshold,
            currentQuality: quality,
          );
    } catch (e) {
      debugPrint('[AutoDownload] _triggerAutoDownload failed: $e');
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
      final streamingHash = _nextEpisodeStreamingTorrentHash;
      debugPrint(
        '[NextEpisodeProxy] handing off to player streaming=${streamingHash != null} '
        'hash=$streamingHash '
        'fileIdx=$_nextEpisodeStreamingFileIndex '
        'url=$_nextEpisodeStreamingProxyUrl',
      );
      // Navigate to next episode
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => VideoPlayerScreen(
            file: nextEpisode,
            isStreaming: streamingHash != null,
            streamingTorrentHash: streamingHash,
            streamingFileIndex: _nextEpisodeStreamingFileIndex,
            streamingProxyUrl: _nextEpisodeStreamingProxyUrl,
          ),
        ),
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
    if (widget.isStreaming) {
      _setupStreamingBufferingDebounce();
      _startPlaybackHealthMonitor();
    }
  }

  Future<void> _exitPlayer() async {
    final playerService = ref.read(playerServiceProvider);
    await playerService.stop();
    if (_isFullscreen) {
      await windowManager.setFullScreen(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );
      // Restore the user's window size that was active before they
      // entered fullscreen — otherwise macOS resets to default.
      final pre = _preFullscreenSize;
      if (pre != null) {
        await windowManager.setSize(pre);
      }
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
    _healthMonitorTimer?.cancel();
    _healthPositionSub?.cancel();
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
                            onShowShortcuts: _showShortcutsDialog,
                            streamingDownloadedRatio: widget.isStreaming
                                ? _streamingDownloadedRatio
                                : null,
                            showId: _currentShowId,
                            onContinueWatchingActivated:
                                _onContinueWatchingActivated,
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
      _monitorNextEpisodeStream(torrent, episode);
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
    EztvTorrent streamTorrent,
    Episode episode,
  ) async {
    final qbtService = ref.read(qbApiServiceProvider);
    final expectedHash = streamTorrent.hash.toLowerCase();

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
        (t) =>
            t.hash.toLowerCase() == expectedHash ||
            streamTorrent.magnetUrl.toLowerCase().contains(
              t.hash.toLowerCase(),
            ),
      );

      if (torrent == null) continue;

      final files = await qbtService.getTorrentFiles(torrent.hash);
      final selectedFile = _selectStreamingFile(files, streamTorrent.fileIdx);
      if (selectedFile == null) continue;

      // Update progress in the indicator
      _showStreamingStatus(
        status: StreamingStatus.buffering,
        message: 'Buffering...',
        episodeCode: episode.episodeCode,
        progress: selectedFile.progress,
      );

      // Match the readiness gate the main streaming session uses
      // (StreamingService._handleBuffering) — bytes downloaded crossing the
      // size-scaled threshold, no piece-level contiguity check. The proxy
      // makes the strict piece check unnecessary: it never serves bytes past
      // the download head, so a hole in the leading pieces just turns into
      // a brief mpv pause-for-cache rather than a frozen demuxer.
      final minBytes = StreamingService.minBufferBytesFor(selectedFile.size);
      final bufferedBytes = (selectedFile.size * selectedFile.progress).round();
      final isReady = bufferedBytes >= minBytes;

      if (isReady && mounted) {
        // Update the next episode to the downloaded file
        final videoFile = await _findVideoFileInPath(
          torrent.contentPath,
          selectedFilePath: selectedFile.name,
          episode: episode,
        );
        if (videoFile != null) {
          // Stand up a LocalStreamingServer so the upcoming
          // VideoPlayerScreen.pushReplacement opens in proxy mode and the
          // seek-bar buffered indicator works for the next episode the same
          // way it does for the first. Register with StreamingService so
          // its lifetime outlives this screen's dispose (pushReplacement
          // pops us before the new screen mounts) and so it gets cleaned
          // up at app shutdown.
          String? proxyUrl;
          try {
            final server = LocalStreamingServer(
              qbt: qbtService,
              filePath: videoFile.path,
              torrentHash: torrent.hash,
              fileIndex: selectedFile.index,
              logTag: 'next',
            );
            await server.start();
            ref
                .read(streamingServiceProvider)
                .registerExternalServer(
                  'next:${torrent.hash}:${selectedFile.index}',
                  server,
                );
            proxyUrl = server.url;
            debugPrint(
              '[NextEpisodeProxy] ready hash=${torrent.hash} '
              'fileIdx=${selectedFile.index} '
              'path=${videoFile.path} '
              'url=$proxyUrl',
            );
          } catch (e) {
            debugPrint('[NextEpisodeProxy] failed to start: $e');
          }

          setState(() {
            _nextEpisode = videoFile;
            _nextEpisodeFromTmdb = null; // Clear TMDB version
            _nextEpisodeStreamingTorrentHash = torrent.hash;
            _nextEpisodeStreamingFileIndex = selectedFile.index;
            _nextEpisodeStreamingProxyUrl = proxyUrl;
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

  TorrentFile? _selectStreamingFile(List<TorrentFile> files, int? fileIdx) {
    if (fileIdx != null && fileIdx >= 0 && fileIdx < files.length) {
      return files[fileIdx];
    }

    final videoFiles = files.where((file) {
      final ext = file.name.split('.').last.toLowerCase();
      return videoExtensions.contains(ext);
    }).toList();

    if (videoFiles.isEmpty) return null;
    videoFiles.sort((a, b) => b.size.compareTo(a.size));
    return videoFiles.first;
  }

  /// Find video file in a content path
  Future<LocalMediaFile?> _findVideoFileInPath(
    String contentPath, {
    String? selectedFilePath,
    Episode? episode,
  }) async {
    try {
      final fileOrDir = FileSystemEntity.typeSync(contentPath);
      List<File> videoFiles = [];
      File? selectedFile;

      if (fileOrDir == FileSystemEntityType.file) {
        final ext = contentPath.split('.').last.toLowerCase();
        if (videoExtensions.contains(ext)) {
          selectedFile = File(contentPath);
          videoFiles.add(selectedFile);
        }
      } else if (fileOrDir == FileSystemEntityType.directory) {
        final dir = Directory(contentPath);
        final selectedFileName = selectedFilePath == null
            ? null
            : p.basename(selectedFilePath.replaceAll(r'\', '/'));

        if (selectedFilePath != null) {
          final segments = selectedFilePath
              .split(RegExp(r'[\\/]'))
              .where((s) => s.isNotEmpty);
          final candidatePath = p.normalize(
            p.join(contentPath, p.joinAll(segments)),
          );
          final candidate = File(candidatePath);
          if (await candidate.exists()) {
            selectedFile = candidate;
          }
        }

        await for (final entity in dir.list(recursive: true)) {
          if (entity is File) {
            final ext = entity.path.split('.').last.toLowerCase();
            if (videoExtensions.contains(ext)) {
              if (selectedFileName != null &&
                  p.basename(entity.path).toLowerCase() ==
                      selectedFileName.toLowerCase()) {
                selectedFile = entity;
              }
              videoFiles.add(entity);
            }
          }
        }
      }

      if (videoFiles.isEmpty) return null;

      videoFiles.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      final file = selectedFile ?? videoFiles.first;
      final stat = file.statSync();
      final fileName = p.basename(file.path);

      return LocalMediaFile(
        path: file.path,
        fileName: fileName,
        sizeBytes: stat.size,
        modifiedDate: stat.modified,
        extension: fileName.split('.').last.toLowerCase(),
        showName: widget.file.showName,
        seasonNumber: episode?.seasonNumber,
        episodeNumber: episode?.episodeNumber,
      );
    } catch (e) {
      debugPrint('Error finding video file: $e');
      return null;
    }
  }

  void _showShortcutsDialog() {
    _onUserInteraction();
    ShortcutsHelpDialog.show(context);
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
      case LogicalKeyboardKey.question:
      case LogicalKeyboardKey.slash:
        // ? on US layouts is Shift+/. Accept either.
        _showShortcutsDialog();
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

/// Center-screen buffering ring shown while mpv is paused-for-cache.
///
/// Theme-driven (violet on-brand spinner, surface-tinted glass background,
/// soft shadow, outline-variant rim) and animated in with a subtle
/// scale + fade so it doesn't hard-cut on screen.
///
/// Optional [label] renders a small chip below the spinner — useful when
/// the surrounding context wants to explain *why* we're buffering (e.g.
/// "Fetching pieces around new position…" after a seek-past-head). Left
/// null on the default call site.
class _BufferingIndicator extends StatelessWidget {
  final String? label;

  const _BufferingIndicator({this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: AppDuration.normal,
        curve: Curves.easeOutCubic,
        builder: (context, t, child) {
          // 0.94 → 1.0 scale + 0 → 1 fade
          return Opacity(
            opacity: t,
            child: Transform.scale(scale: 0.94 + (0.06 * t), child: child),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: scheme.surface.withValues(
                  alpha: AppOpacity.heavy / 255.0,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: scheme.outlineVariant.withValues(
                    alpha: AppOpacity.light / 255.0,
                  ),
                  width: AppBorderWidth.thin,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: AppOpacity.semi / 255.0,
                    ),
                    blurRadius: AppElevation.lg,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: CircularProgressIndicator(
                  strokeWidth: 3.0,
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                ),
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(
                    alpha: AppOpacity.heavy / 255.0,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(
                      alpha: AppOpacity.light / 255.0,
                    ),
                    width: AppBorderWidth.thin,
                  ),
                ),
                child: Text(
                  label!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
