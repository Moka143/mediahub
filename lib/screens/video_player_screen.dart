import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../models/local_media_file.dart';
import '../models/stream_request.dart';
import '../providers/auto_download_provider.dart';
import '../providers/connection_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/player_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/streaming_provider.dart';
import '../services/auto_download_service.dart';
import '../services/local_streaming_server.dart';
import '../services/next_episode_planner.dart';
import '../services/playback_health_monitor.dart';
import '../services/streaming_service.dart';
import '../widgets/next_episode_overlay.dart';
import '../widgets/player/player_keyboard.dart';
import '../widgets/player/resume_prompt.dart';
import '../widgets/player/seek_indicator.dart';
import '../widgets/player/skip_ripple_indicator.dart';
import '../widgets/streaming_status_indicator.dart';
import '../widgets/video_controls.dart';
import '../services/app_logger.dart';

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

  // Binge watching / Next episode state.
  //
  // The *when* — trigger window, overlay-vs-autoplay, and the one-shot
  // guards that used to be four loose booleans here — lives in
  // [NextEpisodePlanner]. This screen keeps the *what*: the resolved
  // episode, the TMDB lookup, and the navigation.
  late final NextEpisodePlanner _planner;
  LocalMediaFile? _nextEpisode;
  Episode? _nextEpisodeFromTmdb; // Next episode from TMDB (not downloaded yet)
  NextEpisodeResult? _nextEpisodeResult; // Full result with availability info
  int? _currentShowId;
  String? _currentImdbId;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _completedSubscription;

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

  /// Subscription to the next-episode [StreamingService] session. Cancelled
  /// on any terminal state and in [dispose].
  StreamSubscription<StreamingSession>? _nextEpisodeSubscription;

  // Streaming status indicator (current-episode health monitor only —
  // next-episode prefetch lives in [_nextPrefetch] beside the CW pill).
  StreamingStatus? _streamingStatus;
  String _streamingMessage = '';
  String? _streamingEpisodeCode;
  double? _streamingProgress;

  NextEpisodePrefetch? _nextPrefetch;
  Timer? _nextPrefetchHideTimer;

  // Debounced buffering state for streaming mode —
  // mpv's buffering signal flickers rapidly when reading at the edge
  // of partially-downloaded data, so we smooth it out.
  bool _streamBuffering = false;
  bool _streamBufferingGrace = false; // suppress indicator right after open
  Timer? _bufferingDebounceTimer;
  StreamSubscription<bool>? _bufferingSubscription;

  /// Watches the player position vs. the torrent's download edge and
  /// pauses/resumes/recovers accordingly. Only created while streaming; owns
  /// all of its own timers and subscriptions. See [PlaybackHealthMonitor].
  PlaybackHealthMonitor? _healthMonitor;

  // Latest 0.0–1.0 download progress for the streaming target file.
  // Drives the buffering overlay's percentage, and the seek-bar's buffered
  // track when no piece map is available. Fed by the monitor's
  // onDownloadedRatio callback; read by build().
  double? _streamingDownloadedRatio;

  // Where those bytes actually are, from the torrent's piece map. Preferred
  // over the scalar above for the seek-bar track: once the user seeks we turn
  // sequential download off, after which "60% downloaded" no longer means
  // "the first 60% is playable". Empty until the first piece-map poll lands,
  // or permanently if qBittorrent won't give us one.
  List<BufferedSpan> _bufferedSpans = const [];

  /// Captured in [initState] so [dispose] can reach it without `ref.read`,
  /// which is not safe there.
  late final StreamingSessionsNotifier _streamingSessions;

  /// Streaming sessions this screen must tear down on dispose. Set to null
  /// the moment a session is handed to a replacement screen — that screen
  /// takes ownership with it, and cancelling here would kill the proxy the
  /// next episode is about to read from.
  String? _ownedSessionId;
  String? _prefetchSessionId;

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
      _streamingDownloadedRatio = widget.initialBufferedRatio!.clamp(0.0, 1.0);
    }
    // Delay initialization to after widget tree is built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keyboardFocus.requestFocus();
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
      if (mounted) setState(() => _mediaOpened = true);
      if (widget.isStreaming) {
        _setupStreamingBufferingDebounce();
        _startPlaybackHealthMonitor();
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

  static const _bufferingShowDelay = Duration(milliseconds: 400);
  static const _bufferingHideDelay = Duration(seconds: 1);
  // Keep this in sync with PlayerService.waitForFirstPlay's default — both
  // values gate the same "still loading?" deadline.
  static const _firstPlayTimeout = Duration(seconds: 7);
  static const _postPlayGrace = Duration(milliseconds: 500);

  /// Build and start the playback health monitor for this streaming session.
  ///
  /// Called from both `_initializePlayer` and `_handleResume`; safe to call
  /// twice because the previous instance is disposed first and the monitor
  /// resets all of its counters in `start()`.
  void _startPlaybackHealthMonitor() {
    final hash = widget.streamingTorrentHash;
    if (hash == null) {
      // Without a hash we can't query torrent state — only the stall detector
      // would be useful, and it'd fire on legitimate user pauses too. Skip.
      return;
    }

    _healthMonitor?.dispose();
    _healthMonitor = PlaybackHealthMonitor(
      player: ref.read(playerProvider),
      qbt: ref.read(qbApiServiceProvider),
      torrentHash: hash,
      fileIndex: widget.streamingFileIndex,
      usingProxy: widget.streamingProxyUrl != null,
      isActive: () => mounted,
      onDownloadedRatio: (ratio) {
        if (!mounted) return;
        if (_streamingDownloadedRatio == null ||
            (ratio - _streamingDownloadedRatio!).abs() > 0.001) {
          setState(() => _streamingDownloadedRatio = ratio);
        }
      },
      onBufferedSpans: (spans) {
        if (!mounted) return;
        if (!listEquals(spans, _bufferedSpans)) {
          setState(() => _bufferedSpans = spans);
        }
      },
      onBuffering: (message, progress) => _showStreamingStatus(
        status: StreamingStatus.buffering,
        message: message,
        progress: progress,
      ),
      onBufferingResolved: _dismissStreamingStatus,
    )..start();
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

    // Skip the whole flow — subscription, TMDB lookup and library rescan —
    // when binge watching is off. The planner would refuse every action
    // anyway, but there's no reason to pay for the round trips.
    if (!_planner.bingeEnabled) return;

    // Attach the position listener UP FRONT — even before we know whether
    // there's a next episode. If we wait until TMDB / local scan resolves
    // (a network round trip + filesystem scan, which can outlast the user
    // crossing the countdown threshold) we miss the show window entirely.
    // The auto-download flow can also surface a next episode much later
    // (after buffering completes), and we want the overlay to fire then
    // too. So: always-attach, lazy-check `_hasNextEpisode()` on each tick.
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted) return;

      final cwOverride = _currentShowId == null
          ? null
          : ref
                .read(autoDownloadProvider)
                .showAutoDownloadOverrides[_currentShowId];

      final action = _planner.evaluatePosition(
        position: position,
        duration: player.state.duration,
        countdownSeconds: ref.read(nextEpisodeCountdownSecondsProvider),
        resumePromptVisible: _showResumePrompt,
        continueWatchingOn: cwOverride == true,
        hasAnyNextEpisode: _hasNextEpisode(),
      );

      switch (action) {
        case NextEpisodeAction.showOverlay:
          setState(() {});
        case NextEpisodeAction.none:
          break;
      }
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
          AppLog.d(
            '[NextEpisode] Found downloaded next episode: ${downloadedNextEp.fileName}',
          );
          if (mounted) {
            setState(() {
              _nextEpisode = downloadedNextEp;
              _nextEpisodeFromTmdb = null;
            });
          }
        } else {
          AppLog.d(
            '[NextEpisode] Next episode S${_nextEpisodeFromTmdb!.seasonNumber}E${_nextEpisodeFromTmdb!.episodeNumber} not downloaded - will offer download',
          );
        }
      }
    } else {
      // TMDB didn't find next episode (network failure, no TMDB match).
      // Fall back to local-only check.
      final localNext = ref.read(nextLocalEpisodeProvider(widget.file));
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

    AppLog.d(
      '[AutoDownload] Checking TMDB for next episode: $showName S${season}E$episode',
    );

    if (showName == null || season == null || episode == null) {
      AppLog.w('[AutoDownload] Missing show info, skipping TMDB check');
      return;
    }

    try {
      final tmdbService = ref.read(tmdbApiServiceProvider);
      final shows = await tmdbService.searchShows(showName);

      AppLog.d(
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
      unawaited(
        ref
            .read(watchProgressProvider.notifier)
            .attachShowId(widget.file.path, show.id),
      );

      // Get full show details with IMDB ID (using append_to_response for external_ids)
      final showDetails = await tmdbService.getShowDetailsWithImdb(show.id);
      _currentImdbId = showDetails.imdbId;

      AppLog.d(
        '[AutoDownload] Show: ${show.name}, TMDB ID: ${show.id}, IMDB ID: $_currentImdbId',
      );

      // Set subtitle context for OpenSubtitles
      if (_currentImdbId != null) {
        ref
            .read(subtitleContextProvider.notifier)
            .setSeriesContext(
              imdbId: _currentImdbId!,
              season: season,
              episode: episode,
            );
        AppLog.d(
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

      AppLog.d(
        '[AutoDownload] Next episode result: ${result.nextEpisode?.episodeCode ?? "none"}, hasNext: ${result.hasNextEpisode}',
      );

      if (mounted) {
        setState(() {
          _nextEpisodeResult = result;
          _nextEpisodeFromTmdb = result.nextEpisode;
        });
      }
    } catch (e) {
      AppLog.e('[AutoDownload] Failed to check TMDB for next episode: $e');
    }
  }

  /// Called when the user flips Continue Watching to explicit-On for this
  /// show. Prefetches the next episode only if we're already past the
  /// progress threshold (so turning On during credits still works). Earlier
  /// than that, the position watcher starts the prefetch at the threshold —
  /// never by jumping to the next episode.
  void _onContinueWatchingActivated() {
    final player = ref.read(playerProvider);
    final state = ref.read(autoDownloadProvider);
    if (!_planner.claimAutoDownloadAtThreshold(
      gateOpen: true,
      position: player.state.position,
      duration: player.state.duration,
      threshold: state.progressThreshold,
    )) {
      AppLog.d(
        '[ContinueWatching] activated — waiting for '
        '${(state.progressThreshold * 100).toInt()}% before prefetch',
      );
      return;
    }
    AppLog.d(
      '[ContinueWatching] activated past threshold — prefetching next episode',
    );
    _triggerAutoDownload();
  }

  void _setupAutoDownloadWatcher() {
    final player = ref.read(playerProvider);
    final state = ref.read(autoDownloadProvider);
    final notifier = ref.read(autoDownloadProvider.notifier);

    AppLog.d(
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
      if (!mounted) return;

      // Re-resolve every tick so toggling the per-show pill (or the global
      // setting) takes effect without restarting playback.
      final state = ref.read(autoDownloadProvider);
      final notifier = ref.read(autoDownloadProvider.notifier);
      final active = notifier.isAutoDownloadActiveForShow(_currentShowId);
      final duration = player.state.duration;

      if (_planner.claimAutoDownloadAtThreshold(
        gateOpen: active,
        position: position,
        duration: duration,
        threshold: state.progressThreshold,
      )) {
        AppLog.d(
          '[AutoDownload] Crossed threshold (${state.progressThreshold}) — '
          'triggering download',
        );
        _triggerAutoDownload();
        return;
      }

      // Diagnostic only: we're past the threshold but the gate is shut.
      // Throttled so a closed gate doesn't log on every position event.
      if (active || duration.inMilliseconds <= 0) return;
      final progress = position.inMilliseconds / duration.inMilliseconds;
      if (progress < state.progressThreshold) return;
      final now = DateTime.now();
      if (now.difference(lastDecisionLogAt).inSeconds < 5) return;
      lastDecisionLogAt = now;
      AppLog.d(
        '[AutoDownload] At ${(progress * 100).toStringAsFixed(1)}% '
        'but gate is closed: enabled=${state.enabled} '
        'overrideForShow=${_currentShowId == null ? "<no-show>" : state.showAutoDownloadOverrides[_currentShowId]} '
        'downloadOnProgress=${state.downloadOnProgress}',
      );
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
        final tmdbService = ref.read(tmdbApiServiceProvider);
        final shows = await tmdbService.searchShows(showName);
        if (shows.isEmpty) {
          AppLog.d(
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
        unawaited(
          ref
              .read(watchProgressProvider.notifier)
              .attachShowId(widget.file.path, show.id),
        );
      }

      // Continue Watching On prefetches the next episode through
      // StreamingService so the hand-off already has a proxy URL — but
      // as a *background* session. The overlay Stream button is the
      // play-now path; reusing it here used to steal `activeSessionId`
      // and the nav safety-net would open ep N+1 on top of ep N.
      final state = ref.read(autoDownloadProvider);
      final cwOverride = state.showAutoDownloadOverrides[showId];
      if (cwOverride == true && _nextEpisodeFromTmdb != null) {
        AppLog.d(
          '[AutoDownload] _triggerAutoDownload → prefetch next episode '
          '(CW on for show $showId)',
        );
        await _prefetchNextEpisode(playWhenReady: false);
        return;
      }

      AppLog.d(
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
      AppLog.e('[AutoDownload] _triggerAutoDownload failed: $e');
    }
  }

  /// Watch for playback completion to auto-play next episode if available.
  ///
  /// Only Continue Watching **On** jumps automatically here. Auto uses the
  /// Up Next card (and its countdown); Off does nothing.
  void _setupPlaybackCompletionWatcher() {
    final player = ref.read(playerProvider);

    _completedSubscription = player.stream.completed.listen((completed) async {
      if (!completed || !mounted) return;

      final cwOverride = _currentShowId == null
          ? null
          : ref
                .read(autoDownloadProvider)
                .showAutoDownloadOverrides[_currentShowId];
      if (cwOverride != true) return;

      AppLog.d(
        '[ContinueWatching] Playback completed — handing off to next episode',
      );

      if (_nextEpisode != null) {
        _onPlayNextEpisode();
        return;
      }

      if (_nextEpisodeDownloadStarted && _downloadingEpisode != null) {
        await _tryPlayDownloadedNextEpisode();
        return;
      }

      await _checkAndPlayNextEpisode();
    });
  }

  /// Try to play the next episode that was being downloaded
  Future<void> _tryPlayDownloadedNextEpisode() async {
    final episode = _downloadingEpisode;
    if (episode == null) return;

    final showName = widget.file.showName;
    if (showName == null) return;

    AppLog.d(
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
      AppLog.d(
        '[AutoDownload] Found downloaded episode! Playing: ${nextFile.fileName}',
      );

      // Dismiss any streaming indicator
      _dismissStreamingStatus();
      _dismissNextPrefetch();

      final playerService = ref.read(playerServiceProvider);
      await playerService.stop();
      if (!mounted) return;

      final fileToPlay = nextFile; // Capture non-null value
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: fileToPlay)),
      );
    } else {
      AppLog.w(
        '[AutoDownload] Downloaded file not found yet - may still be downloading',
      );
      // Show message that file is still downloading
      if (mounted) {
        _setNextEpisodePrefetch(
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

    if (showName == null || currentSeason == null || currentEpisode == null) {
      return;
    }

    // Calculate next episode number
    final nextEpisodeNum = currentEpisode + 1;

    AppLog.d(
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
    nextFile ??= scanner.findEpisodeFile(
      files,
      showName: showName,
      season: currentSeason + 1,
      episode: 1,
    );

    if (nextFile != null && mounted) {
      AppLog.d(
        '[AutoDownload] Found next episode! Playing: ${nextFile.fileName}',
      );

      final playerService = ref.read(playerServiceProvider);
      await playerService.stop();
      if (!mounted) return;

      final fileToPlay = nextFile; // Capture non-null value
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => VideoPlayerScreen(file: fileToPlay)),
      );
    }
  }

  void _onPlayNextEpisode() async {
    _positionSubscription?.cancel();
    _dismissStreamingStatus();
    _dismissNextPrefetch();
    _consumeNextEpisodePrompt();

    final nextEpisode = _nextEpisode;
    if (nextEpisode == null) return;

    // Stop current playback
    final playerService = ref.read(playerServiceProvider);
    await playerService.stop();

    if (mounted) {
      final streamingHash = _nextEpisodeStreamingTorrentHash;
      // Hand the prefetch session to the replacement screen. Nulled here so
      // our dispose() — which runs right after pushReplacement — doesn't
      // cancel the session the next episode is about to play from.
      final handoffSessionId = _prefetchSessionId;
      _prefetchSessionId = null;
      AppLog.d(
        '[NextEpisodeProxy] handing off to player streaming=${streamingHash != null} '
        'hash=$streamingHash '
        'fileIdx=$_nextEpisodeStreamingFileIndex '
        'url=$_nextEpisodeStreamingProxyUrl '
        'session=$handoffSessionId',
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
            streamingSessionId: handoffSessionId,
          ),
        ),
      );
    }
  }

  void _minimizeNextEpisode() {
    setState(() => _planner.minimizeOverlay());
  }

  void _restoreNextEpisode() {
    setState(() => _planner.restoreOverlay());
  }

  void _consumeNextEpisodePrompt() {
    setState(() => _planner.consumeOverlay());
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
    if (mounted) setState(() => _mediaOpened = true);
    if (widget.isStreaming) {
      _setupStreamingBufferingDebounce();
      _startPlaybackHealthMonitor();
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
    _onUserInteraction();
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
    _onUserInteraction();
  }

  void _seekBackward() {
    _showSkipIndicator(forward: false);
    ref.read(playerServiceProvider).seekBackward(seconds: 10);
    _onUserInteraction();
  }

  void _seekForward() {
    _showSkipIndicator(forward: true);
    ref.read(playerServiceProvider).seekForward(seconds: 10);
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
    _nextEpisodeSubscription?.cancel();
    _nextPrefetchHideTimer?.cancel();
    _bufferingDebounceTimer?.cancel();
    _bufferingSubscription?.cancel();
    // Synchronous and ref-free — the monitor owns its own timer and stream
    // subscription and needs no providers to shut down.
    _healthMonitor?.dispose();
    _keyboardFocus.dispose();
    // Release the sessions this screen owns: cancelSession stops the 2 s
    // monitoring timer and shuts down the LocalStreamingServer. Uses the
    // notifier captured in initState, not ref.read — see below.
    for (final sessionId in {_ownedSessionId, _prefetchSessionId}) {
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
        ? (_streamBuffering && !_streamBufferingGrace)
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
          onHover: (_) => _onUserInteraction(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Main video area with gesture detection
              GestureDetector(
                onTap: _onUserInteraction,
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
                      _BufferingIndicator(
                        label: widget.isStreaming
                            ? _bufferingLabel(_streamingDownloadedRatio)
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
                                ? _streamingDownloadedRatio
                                : null,
                            bufferedSpans: widget.isStreaming
                                ? _bufferedSpans
                                : const [],
                            showId: _currentShowId,
                            onContinueWatchingActivated:
                                _onContinueWatchingActivated,
                            nextEpisodePrefetch: _nextPrefetch,
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
                  (_nextEpisode != null || _nextEpisodeFromTmdb != null))
                Positioned(
                  right: AppSpacing.lg,
                  bottom: 110,
                  child: NextEpisodeOverlay(
                    episodeCode:
                        _nextEpisode?.episodeCode ??
                        _nextEpisodeFromTmdb?.episodeCode ??
                        '',
                    title: _nextEpisode != null
                        ? (_nextEpisode!.showName ?? _nextEpisode!.fileName)
                        : (_nextEpisodeFromTmdb?.name ?? ''),
                    countdownSeconds: _nextEpisode != null
                        ? ref.read(nextEpisodeCountdownSecondsProvider)
                        : null,
                    minimized: _planner.overlayMinimized,
                    playLabel: _nextEpisode != null ? 'Play' : 'Stream',
                    onPlay: _nextEpisode != null
                        ? _onPlayNextEpisode
                        : _onStreamNextEpisode,
                    onMinimize: _minimizeNextEpisode,
                    onDismiss: _consumeNextEpisodePrompt,
                    onRestore: _restoreNextEpisode,
                  ),
                ),

              // Current-episode health-monitor chip (next-episode prefetch
              // is the spinner beside the Continue Watching pill).
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

  void _dismissNextPrefetch() {
    _nextPrefetchHideTimer?.cancel();
    if (!mounted) return;
    setState(() => _nextPrefetch = null);
  }

  void _setNextEpisodePrefetch({
    required StreamingStatus status,
    String? episodeCode,
    double? progress,
    String? message,
    int downloadRateBytesPerSec = 0,
  }) {
    if (!mounted) return;
    final firstAppearance = _nextPrefetch == null;
    _nextPrefetchHideTimer?.cancel();
    setState(() {
      _nextPrefetch = NextEpisodePrefetch(
        status: status,
        episodeCode: episodeCode ?? _nextPrefetch?.episodeCode,
        progress: progress,
        message: message,
        downloadRateBytesPerSec: downloadRateBytesPerSec,
      );
    });
    if (firstAppearance) _onUserInteraction();
    if (status == StreamingStatus.ready) {
      _nextPrefetchHideTimer = Timer(
        const Duration(seconds: 4),
        _dismissNextPrefetch,
      );
    }
  }

  /// Compose the chip text shown under the buffering spinner during
  /// streaming. Falls back to a plain "Buffering…" when we don't have
  /// the download ratio yet (very first frames after open).
  String _bufferingLabel(double? downloadedRatio) {
    if (downloadedRatio == null) return 'Buffering…';
    final pct = (downloadedRatio * 100).clamp(0, 100).toStringAsFixed(1);
    return 'Buffering — $pct% downloaded';
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

  /// Overlay "Stream" button — prefetch and open the next episode as soon
  /// as the buffer is ready. Continue Watching On uses the same fetch with
  /// [playWhenReady] false so the current episode keeps playing.
  Future<void> _onStreamNextEpisode() =>
      _prefetchNextEpisode(playWhenReady: true);

  /// Start a next-episode streaming session without making it the global
  /// active session (that would trip the nav safety-net into opening it).
  Future<void> _prefetchNextEpisode({required bool playWhenReady}) async {
    AppLog.d(
      '[StreamingService] Prefetch next episode playWhenReady=$playWhenReady',
    );
    final episode = _nextEpisodeFromTmdb;
    AppLog.d(
      '[StreamingService] Episode: ${episode?.episodeCode}, IMDB: $_currentImdbId',
    );

    if (episode == null || _currentImdbId == null) {
      AppLog.w('[StreamingService] Missing episode or IMDB ID, canceling');
      if (playWhenReady) _consumeNextEpisodePrompt();
      return;
    }

    final autoDownloadService = ref.read(autoDownloadServiceProvider);
    final settings = ref.read(settingsProvider);
    final quality =
        widget.file.quality ?? ref.read(autoDownloadProvider).defaultQuality;

    AppLog.d(
      '[StreamingService] Searching for torrent: S${episode.seasonNumber}E${episode.episodeNumber} quality: $quality',
    );

    if (playWhenReady) {
      _consumeNextEpisodePrompt();
    }

    _setNextEpisodePrefetch(
      status: StreamingStatus.searching,
      message: playWhenReady
          ? 'Finding torrent...'
          : 'Next episode: finding source…',
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

    AppLog.d('[StreamingService] Torrent found: ${torrent?.title ?? "null"}');

    if (torrent == null) {
      _setNextEpisodePrefetch(
        status: StreamingStatus.error,
        message: 'No torrent found',
        episodeCode: episode.episodeCode,
      );
      return;
    }

    AppLog.d(
      '[StreamingService] Starting stream download: ${torrent.magnetUrl.substring(0, 50)}...',
    );
    if (torrent.fileIdx != null) {
      AppLog.d(
        '[StreamingService] Season pack detected - will select file index: ${torrent.fileIdx}',
      );
    }

    // Route through StreamingService rather than adding the torrent here.
    // This path used to call AutoDownloadService.downloadNextEpisode and then
    // re-implement the whole readiness workflow — file selection, the buffer
    // threshold, the on-disk file lookup and the proxy standup — in this
    // screen. Two copies meant two behaviours: notably the local copy added
    // torrents with firstLastPiecePrio: true, which StreamingService
    // deliberately sets to false because prioritising the LAST piece breaks
    // the strict in-order delivery sequential mode exists to provide.
    final session = await ref
        .read(streamingSessionsProvider.notifier)
        .startStreamingRequest(
          request: StreamRequest.fromEztv(torrent),
          showImdbId: _currentImdbId,
          showName: widget.file.showName,
          season: episode.seasonNumber,
          episode: episode.episodeNumber,
          episodeCode: episode.episodeCode,
          savePath: settings.defaultSavePath,
          makeActive: false,
          // Competing with the current episode for disk/peers — a 10-minute
          // projected wait is normal. Aborting would freeze the pill on
          // "too slow" and stop progress updates.
          allowSlowBuffer: !playWhenReady,
        );

    if (!mounted) return;

    if (session == null) {
      _setNextEpisodePrefetch(
        status: StreamingStatus.error,
        message: 'Failed to start stream',
        episodeCode: episode.episodeCode,
      );
      return;
    }

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

    _prefetchSessionId = session.id;
    setState(() {
      _nextEpisodeDownloadStarted = true;
      _downloadingEpisode = episode;
    });

    _setNextEpisodePrefetch(
      status: StreamingStatus.buffering,
      message: playWhenReady ? 'Buffering started' : 'Next episode: buffering…',
      episodeCode: episode.episodeCode,
      progress: 0.0,
    );

    _monitorNextEpisodeStream(
      session.id,
      episode,
      playWhenReady: playWhenReady,
    );
  }

  /// Mirror a next-episode [StreamingService] session into this screen's
  /// status indicator, and capture the proxy details when it turns ready.
  ///
  /// This used to be a hand-rolled 10-minute poll loop that re-derived file
  /// selection, the buffer threshold, the on-disk path and the proxy — all
  /// of which `StreamingService` already does for the primary playback path.
  /// Subscribing to the session means one implementation, and the session
  /// (not this screen) owns the proxy's lifetime, so it correctly survives
  /// the `pushReplacement` that pops us before the next screen mounts.
  void _monitorNextEpisodeStream(
    String sessionId,
    Episode episode, {
    required bool playWhenReady,
  }) {
    _nextEpisodeSubscription?.cancel();
    final service = ref.read(streamingServiceProvider);

    void apply(StreamingSession session) {
      if (!mounted) return;

      switch (session.state) {
        case StreamingState.addingTorrent:
        case StreamingState.selectingFiles:
        case StreamingState.buffering:
          _setNextEpisodePrefetch(
            status: StreamingStatus.buffering,
            message: playWhenReady
                ? 'Buffering...'
                : 'Next episode: buffering…',
            episodeCode: episode.episodeCode,
            progress: session.bufferProgress,
            downloadRateBytesPerSec: session.downloadRateBytesPerSec,
          );

        case StreamingState.ready:
        case StreamingState.playing:
          final videoFile = session.videoFile;
          if (videoFile == null) return;
          setState(() {
            _nextEpisode = videoFile;
            _nextEpisodeFromTmdb = null; // Clear TMDB version
            _nextEpisodeStreamingTorrentHash = session.torrentHash;
            _nextEpisodeStreamingFileIndex = session.selectedFileIndex;
            _nextEpisodeStreamingProxyUrl = session.streamUrl;
          });
          _nextEpisodeSubscription?.cancel();
          _nextEpisodeSubscription = null;
          if (playWhenReady) {
            _onPlayNextEpisode();
          } else {
            _setNextEpisodePrefetch(
              status: StreamingStatus.ready,
              message: 'Next episode ready',
              episodeCode: episode.episodeCode,
              progress: session.bufferProgress,
            );
          }

        case StreamingState.error:
          _setNextEpisodePrefetch(
            status: StreamingStatus.error,
            message: session.errorMessage ?? 'Streaming failed',
            episodeCode: episode.episodeCode,
          );
          _nextEpisodeSubscription?.cancel();
          _nextEpisodeSubscription = null;

        case StreamingState.cancelled:
        case StreamingState.idle:
          _prefetchSessionId = null;
          _dismissNextPrefetch();
          _nextEpisodeSubscription?.cancel();
          _nextEpisodeSubscription = null;
      }
    }

    // Broadcast streams don't replay — apply the snapshot we already have
    // so the pill isn't stuck on "finding source" until the next 2 s poll.
    final current = service.getSession(sessionId);
    if (current != null) apply(current);

    _nextEpisodeSubscription = service
        .getSessionStream(sessionId)
        ?.listen(apply);
  }

  void _showShortcutsDialog() {
    showPlayerShortcutsDialog(context, onUserInteraction: _onUserInteraction);
  }

  void _handleKeyEvent(KeyEvent event, WidgetRef ref) {
    handlePlayerKeyEvent(
      event,
      ref: ref,
      isFullscreen: _isFullscreen,
      onUserInteraction: _onUserInteraction,
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
