import 'dart:async';

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
import '../providers/settings_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/streaming_provider.dart';
import '../services/auto_download_service.dart';
import '../services/local_streaming_server.dart';
import '../services/next_episode_planner.dart';
import '../services/playback_health_monitor.dart';
import '../services/streaming_service.dart';
import '../utils/formatters.dart';
import '../widgets/next_episode_overlay.dart';
import '../widgets/shortcuts_help_dialog.dart';
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

  /// Watches the player position vs. the torrent's download edge and
  /// pauses/resumes/recovers accordingly. Only created while streaming; owns
  /// all of its own timers and subscriptions. See [PlaybackHealthMonitor].
  PlaybackHealthMonitor? _healthMonitor;

  // Latest 0.0–1.0 download progress for the streaming target file.
  // Drives the seek-bar's buffered-track in streaming mode. Fed by the
  // monitor's onDownloadedRatio callback; read by build().
  double? _streamingDownloadedRatio;

  @override
  void initState() {
    super.initState();
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
        hasPlayableNextEpisode: _nextEpisode != null,
        hasAnyNextEpisode: _hasNextEpisode(),
      );

      switch (action) {
        case NextEpisodeAction.autoPlay:
          AppLog.d(
            '[ContinueWatching] auto-playing next episode '
            '(showId=$_currentShowId, position=${position.inSeconds}s)',
          );
          _onPlayNextEpisode();
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
      final tmdbService = ref.read(tmdbServiceProvider);
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
  /// show. Kicks the next-episode auto-download off **immediately** instead
  /// of waiting for the progress threshold. Idempotent: the existing
  /// planner's auto-download one-shot means a no-op if a download is already
  /// in flight.
  void _onContinueWatchingActivated() {
    if (!_planner.claimAutoDownloadNow()) {
      AppLog.d(
        '[ContinueWatching] activated — auto-download already in flight, '
        'no kickstart needed',
      );
      return;
    }
    AppLog.d(
      '[ContinueWatching] activated — kicking off auto-download immediately',
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
        final tmdbService = ref.read(tmdbServiceProvider);
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
        AppLog.d(
          '[AutoDownload] _triggerAutoDownload → _onStreamNextEpisode '
          '(CW on for show $showId)',
        );
        await _onStreamNextEpisode();
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

  /// Watch for playback completion to auto-play next episode if available
  void _setupPlaybackCompletionWatcher() {
    final player = ref.read(playerProvider);

    _completedSubscription = player.stream.completed.listen((completed) async {
      if (!completed || !mounted) return;

      AppLog.d(
        '[AutoDownload] Playback completed, checking for next episode...',
      );

      // If we started downloading the next episode, check if it's ready
      if (_nextEpisodeDownloadStarted && _downloadingEpisode != null) {
        AppLog.d(
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

    final nextEpisode = _nextEpisode;
    if (nextEpisode == null) return;

    // Stop current playback
    final playerService = ref.read(playerServiceProvider);
    await playerService.stop();

    if (mounted) {
      final streamingHash = _nextEpisodeStreamingTorrentHash;
      AppLog.d(
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
      _planner.dismissOverlay();
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
    _bufferingDebounceTimer?.cancel();
    _bufferingSubscription?.cancel();
    // Synchronous and ref-free — the monitor owns its own timer and stream
    // subscription and needs no providers to shut down.
    _healthMonitor?.dispose();
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
                onTap: _planner.overlayVisible ? null : _onUserInteraction,
                onDoubleTap: _planner.overlayVisible ? null : _onDoubleTap,
                onHorizontalDragStart: _planner.overlayVisible
                    ? null
                    : _onHorizontalDragStart,
                onHorizontalDragUpdate: _planner.overlayVisible
                    ? null
                    : _onHorizontalDragUpdate,
                onHorizontalDragEnd: _planner.overlayVisible
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

                    // Buffering indicator — in streaming mode, surface the
                    // download progress so a long pause-for-cache shows the
                    // user the torrent is actually progressing.
                    if (isBuffering)
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
                            onSeekForward: _seekForward,
                            onSeekBackward: _seekBackward,
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
              if (_planner.overlayVisible &&
                  (_nextEpisode != null || _nextEpisodeFromTmdb != null))
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.5),
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
            Formatters.formatPlaybackDuration(
              targetTime.isNegative ? Duration.zero : targetTime,
            ),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
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
                    'Last position: ${Formatters.formatPlaybackDuration(_resumePosition ?? Duration.zero)}',
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
              color: Colors.black.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
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
                    color: theme.colorScheme.secondary.withValues(alpha: 0.2),
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
    AppLog.d('[StreamingService] Stream button pressed');
    final episode = _nextEpisodeFromTmdb;
    AppLog.d(
      '[StreamingService] Episode: ${episode?.episodeCode}, IMDB: $_currentImdbId',
    );

    if (episode == null || _currentImdbId == null) {
      AppLog.w('[StreamingService] Missing episode or IMDB ID, canceling');
      _onCancelNextEpisode();
      return;
    }

    final autoDownloadService = ref.read(autoDownloadServiceProvider);
    final settings = ref.read(settingsProvider);
    final quality =
        widget.file.quality ?? ref.read(autoDownloadProvider).defaultQuality;

    AppLog.d(
      '[StreamingService] Searching for torrent: S${episode.seasonNumber}E${episode.episodeNumber} quality: $quality',
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

    AppLog.d('[StreamingService] Torrent found: ${torrent?.title ?? "null"}');

    if (torrent == null) {
      _showStreamingStatus(
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
        );

    if (!mounted) return;

    if (session == null) {
      _showStreamingStatus(
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

    setState(() {
      _nextEpisodeDownloadStarted = true;
      _downloadingEpisode = episode;
    });

    _showStreamingStatus(
      status: StreamingStatus.buffering,
      message: 'Buffering started',
      episodeCode: episode.episodeCode,
      progress: 0.0,
    );

    _monitorNextEpisodeStream(session.id, episode);
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
  void _monitorNextEpisodeStream(String sessionId, Episode episode) {
    _nextEpisodeSubscription?.cancel();
    _nextEpisodeSubscription = ref
        .read(streamingServiceProvider)
        .getSessionStream(sessionId)
        ?.listen((session) {
          if (!mounted) return;

          switch (session.state) {
            case StreamingState.addingTorrent:
            case StreamingState.selectingFiles:
            case StreamingState.buffering:
              _showStreamingStatus(
                status: StreamingStatus.buffering,
                message: 'Buffering...',
                episodeCode: episode.episodeCode,
                progress: session.bufferProgress,
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
              _showStreamingStatus(
                status: StreamingStatus.ready,
                message: 'Ready to play!',
                episodeCode: episode.episodeCode,
              );
              _nextEpisodeSubscription?.cancel();
              _nextEpisodeSubscription = null;

            case StreamingState.error:
              _showStreamingStatus(
                status: StreamingStatus.error,
                message: session.errorMessage ?? 'Streaming failed',
                episodeCode: episode.episodeCode,
              );
              _nextEpisodeSubscription?.cancel();
              _nextEpisodeSubscription = null;

            case StreamingState.cancelled:
            case StreamingState.idle:
              _dismissStreamingStatus();
              _nextEpisodeSubscription?.cancel();
              _nextEpisodeSubscription = null;
          }
        });
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
        _seekBackward();
        break;
      case LogicalKeyboardKey.arrowRight:
        _seekForward();
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
                color: Colors.black.withValues(alpha: 0.50),
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
