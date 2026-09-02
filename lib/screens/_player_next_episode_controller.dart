import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/episode.dart';
import '../models/local_media_file.dart';
import '../models/stream_request.dart';
import '../providers/auto_download_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/app_logger.dart';
import '../services/next_episode_planner.dart';
import '../services/streaming_service.dart';
import '../widgets/streaming_status_indicator.dart';

/// The next-episode half of the video player: binge overlay, TMDB lookup,
/// auto-download, prefetch, and the hand-off to the next episode's player.
///
/// This was 740 lines inside `_VideoPlayerScreenState` — 43% of that file —
/// sharing one scope with playback, gestures, fullscreen and rendering. It
/// brought four `StreamSubscription`s, a `Timer` and a streaming-session id
/// into a `dispose()` that already had nine other things to cancel, which is
/// precisely the async-lifecycle bug class `analysis_options.yaml` names as
/// this app's most common regression.
///
/// **Why a mixin and not a controller class.** [NextEpisodePlanner]'s
/// docstring already rejected a standalone class: this flow needs `ref`,
/// `context`, `mounted` and `setState`, so extracting it that way "would mean
/// a constructor full of callbacks that just relay back to the widget — more
/// indirection for no more testability". A mixin keeps all four in scope, so
/// the move is verbatim and the screen keeps reading [nextEpisode] and
/// [nextPrefetch] as plain fields. Same shape as
/// [DetailsPlaybackController], which did this for the details screens.
///
/// The split with [NextEpisodePlanner] is unchanged: the planner owns the
/// *decisions* — when to offer, the one-shot guards — and is unit-tested;
/// this mixin owns the *side effects* — subscriptions, TMDB, qBittorrent,
/// navigation — which need a live stack. Moving the code did not move that
/// boundary.
///
/// Members are public because a `_name` declared here would be invisible to
/// `video_player_screen.dart`, which reads [nextEpisode] and [planner] in
/// `build()`.
mixin PlayerNextEpisodeController<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  // ── What the host screen must provide ──────────────────────────────────

  /// The episode currently playing. Stands in for `widget.file`, which this
  /// mixin cannot reach through the generic `T`.
  LocalMediaFile get playingFile;

  /// Binge decisions and one-shot guards. Owned by the screen because
  /// `build()` reads it too.
  NextEpisodePlanner get planner;

  /// True while the resume dialog is up — suppresses the countdown so the
  /// two prompts never overlap.
  bool get resumePromptVisible;

  /// Reset the screen's auto-hiding chrome. Called when the prefetch pill
  /// first appears, so it is not born invisible.
  void onUserInteraction();

  /// Clear the current-episode health-monitor chip.
  void dismissStreamingStatus();

  /// Replace this route with a player for [file].
  ///
  /// Navigation is the widget's job, not this mixin's: building a
  /// `VideoPlayerScreen` here would make the two files import each other, and
  /// `BuildContext` belongs on the screen side of the seam. The streaming
  /// arguments are null on the from-disk path, which has no proxy to hand on.
  void openReplacementPlayer(
    LocalMediaFile file, {
    String? torrentHash,
    int? fileIndex,
    String? proxyUrl,
    String? sessionId,
  });

  // ── Owned state ────────────────────────────────────────────────────────

  LocalMediaFile? nextEpisode;

  Episode? nextEpisodeFromTmdb; // Next episode from TMDB (not downloaded yet)

  int? currentShowId;

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
  /// auto-next-episode handoff in [onPlayNextEpisode]. Without this the
  /// new VideoPlayerScreen would open in direct-disk mode and the seek-bar
  /// buffered region wouldn't update.
  String? _nextEpisodeStreamingProxyUrl;

  StreamSubscription<Duration>? _autoDownloadSubscription;

  /// Subscription to the next-episode [StreamingService] session. Cancelled
  /// on any terminal state and in [dispose].
  StreamSubscription<StreamingSession>? _nextEpisodeSubscription;

  NextEpisodePrefetch? nextPrefetch;

  Timer? _nextPrefetchHideTimer;

  String? prefetchSessionId;

  void setupNextEpisodeWatcher() async {
    final player = ref.read(playerProvider);

    // Skip the whole flow — subscription, TMDB lookup and library rescan —
    // when binge watching is off. The planner would refuse every action
    // anyway, but there's no reason to pay for the round trips.
    if (!planner.bingeEnabled) return;

    // Attach the position listener UP FRONT — even before we know whether
    // there's a next episode. If we wait until TMDB / local scan resolves
    // (a network round trip + filesystem scan, which can outlast the user
    // crossing the countdown threshold) we miss the show window entirely.
    // The auto-download flow can also surface a next episode much later
    // (after buffering completes), and we want the overlay to fire then
    // too. So: always-attach, lazy-check `hasNextEpisode()` on each tick.
    _positionSubscription = player.stream.position.listen((position) {
      if (!mounted) return;

      final cwOverride = currentShowId == null
          ? null
          : ref
                .read(autoDownloadProvider)
                .showAutoDownloadOverrides[currentShowId];

      final action = planner.evaluatePosition(
        position: position,
        duration: player.state.duration,
        countdownSeconds: ref.read(nextEpisodeCountdownSecondsProvider),
        resumePromptVisible: resumePromptVisible,
        continueWatchingOn: cwOverride == true,
        hasAnyNextEpisode: hasNextEpisode(),
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

    if (nextEpisodeFromTmdb != null) {
      final showName = playingFile.showName;
      if (showName != null) {
        final scanner = ref.read(localMediaScannerProvider);
        final files = await scanner.scanDirectory();

        final downloadedNextEp = scanner.findEpisodeFile(
          files,
          showName: showName,
          season: nextEpisodeFromTmdb!.seasonNumber,
          episode: nextEpisodeFromTmdb!.episodeNumber,
        );

        if (downloadedNextEp != null) {
          AppLog.d(
            '[NextEpisode] Found downloaded next episode: ${downloadedNextEp.fileName}',
          );
          if (mounted) {
            setState(() {
              nextEpisode = downloadedNextEp;
              nextEpisodeFromTmdb = null;
            });
          }
        } else {
          AppLog.d(
            '[NextEpisode] Next episode S${nextEpisodeFromTmdb!.seasonNumber}E${nextEpisodeFromTmdb!.episodeNumber} not downloaded - will offer download',
          );
        }
      }
    } else {
      // TMDB didn't find next episode (network failure, no TMDB match).
      // Fall back to local-only check.
      final localNext = ref.read(nextLocalEpisodeProvider(playingFile));
      if (localNext != null && mounted) {
        setState(() => nextEpisode = localNext);
      }
    }
  }

  bool hasNextEpisode() => nextEpisode != null || nextEpisodeFromTmdb != null;

  /// Check TMDB for next episode when no downloaded episode is available
  Future<void> _checkTmdbForNextEpisode() async {
    final file = playingFile;
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
      // `currentShowId` to decide whether to render the per-show
      // Continue Watching toggle. Without the rebuild signal the pill
      // wouldn't appear until some other state change triggered build().
      if (mounted) {
        setState(() => currentShowId = show.id);
      } else {
        currentShowId = show.id;
      }
      unawaited(
        ref
            .read(watchProgressProvider.notifier)
            .attachShowId(playingFile.path, show.id),
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
        setState(() => nextEpisodeFromTmdb = result.nextEpisode);
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
  void onContinueWatchingActivated() {
    final player = ref.read(playerProvider);
    final state = ref.read(autoDownloadProvider);
    if (!planner.claimAutoDownloadAtThreshold(
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

  void setupAutoDownloadWatcher() {
    final player = ref.read(playerProvider);
    final state = ref.read(autoDownloadProvider);
    final notifier = ref.read(autoDownloadProvider.notifier);

    AppLog.d(
      '[AutoDownload] Attached watcher: '
      'global.enabled=${state.enabled} '
      'global.downloadOnProgress=${state.downloadOnProgress} '
      'overrides=${state.showAutoDownloadOverrides} '
      'threshold=${state.progressThreshold} '
      'active(now)=${notifier.isAutoDownloadActiveForShow(currentShowId)} '
      'showId=$currentShowId',
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
      final active = notifier.isAutoDownloadActiveForShow(currentShowId);
      final duration = player.state.duration;

      if (planner.claimAutoDownloadAtThreshold(
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
        'overrideForShow=${currentShowId == null ? "<no-show>" : state.showAutoDownloadOverrides[currentShowId]} '
        'downloadOnProgress=${state.downloadOnProgress}',
      );
    });
  }

  Future<void> _triggerAutoDownload() async {
    final file = playingFile;

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
      var showId = currentShowId;
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
            currentShowId = showId;
            _currentImdbId = imdbId;
          });
        }
        unawaited(
          ref
              .read(watchProgressProvider.notifier)
              .attachShowId(playingFile.path, show.id),
        );
      }

      // Continue Watching On prefetches the next episode through
      // StreamingService so the hand-off already has a proxy URL — but
      // as a *background* session. The overlay Stream button is the
      // play-now path; reusing it here used to steal `activeSessionId`
      // and the nav safety-net would open ep N+1 on top of ep N.
      final state = ref.read(autoDownloadProvider);
      final cwOverride = state.showAutoDownloadOverrides[showId];
      if (cwOverride == true && nextEpisodeFromTmdb != null) {
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

      // Not awaited: this reaches out to the indexer and qBittorrent.
      // Playback must not wait on it.
      unawaited(
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
            ),
      );
    } catch (e) {
      AppLog.e('[AutoDownload] _triggerAutoDownload failed: $e');
    }
  }

  /// Watch for playback completion to auto-play next episode if available.
  ///
  /// Only Continue Watching **On** jumps automatically here. Auto uses the
  /// Up Next card (and its countdown); Off does nothing.
  void setupPlaybackCompletionWatcher() {
    final player = ref.read(playerProvider);

    _completedSubscription = player.stream.completed.listen((completed) async {
      if (!completed || !mounted) return;

      final cwOverride = currentShowId == null
          ? null
          : ref
                .read(autoDownloadProvider)
                .showAutoDownloadOverrides[currentShowId];
      if (cwOverride != true) return;

      AppLog.d(
        '[ContinueWatching] Playback completed — handing off to next episode',
      );

      if (nextEpisode != null) {
        onPlayNextEpisode();
        return;
      }

      await _playNextEpisodeFromDisk(
        target: _nextEpisodeDownloadStarted ? _downloadingEpisode : null,
      );
    });
  }

  /// Find the next episode on disk and hand the player over to it.
  ///
  /// [target] is the episode a prefetch was downloading, when there is one;
  /// that path waits for the file to be finalised before scanning. Otherwise
  /// the candidates come from TMDB's answer if we have it, falling back to
  /// "next in this season, then first of the next".
  ///
  /// Replaces two methods that answered the same question by different rules.
  /// The fallback one hardcoded `season + 1, episode 1` while ignoring the
  /// TMDB result this screen was already holding, so a show whose season
  /// numbering does not follow that shape jumped to the wrong episode or to
  /// none at all.
  Future<void> _playNextEpisodeFromDisk({Episode? target}) async {
    final showName = playingFile.showName;
    if (showName == null) return;

    final season = playingFile.seasonNumber;
    final episode = playingFile.episodeNumber;
    final fromTmdb = nextEpisodeFromTmdb;

    final candidates = <({int season, int episode})>[
      if (target != null)
        (season: target.seasonNumber, episode: target.episodeNumber)
      else ...[
        // TMDB is authoritative about what comes next; the arithmetic below
        // is only a fallback for when the lookup failed.
        if (fromTmdb != null)
          (season: fromTmdb.seasonNumber, episode: fromTmdb.episodeNumber),
        if (season != null && episode != null) ...[
          (season: season, episode: episode + 1),
          (season: season + 1, episode: 1),
        ],
      ],
    ];
    if (candidates.isEmpty) return;

    if (target != null) {
      // The file may have landed seconds ago — let the scanner catch up.
      await ref.read(refreshLocalMediaProvider)();
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
    }

    final scanner = ref.read(localMediaScannerProvider);
    final files = await scanner.scanDirectory();
    if (!mounted) return;

    for (final candidate in candidates) {
      final match = scanner.findEpisodeFile(
        files,
        showName: showName,
        season: candidate.season,
        episode: candidate.episode,
      );
      if (match == null) continue;

      AppLog.d('[NextEpisode] Playing ${match.fileName} from disk');
      dismissStreamingStatus();
      dismissNextPrefetch();
      await ref.read(playerServiceProvider).stop();
      if (!mounted) return;

      openReplacementPlayer(match);
      return;
    }

    if (target != null) {
      AppLog.w('[NextEpisode] ${target.episodeCode} is not on disk yet');
      setNextEpisodePrefetch(
        status: StreamingStatus.buffering,
        message: 'Still downloading. Check Library when ready.',
        episodeCode: target.episodeCode,
      );
    }
  }

  void onPlayNextEpisode() async {
    unawaited(_positionSubscription?.cancel());
    dismissStreamingStatus();
    dismissNextPrefetch();
    consumeNextEpisodePrompt();

    final target = nextEpisode;
    if (target == null) return;

    // Stop current playback
    final playerService = ref.read(playerServiceProvider);
    await playerService.stop();

    if (mounted) {
      final streamingHash = _nextEpisodeStreamingTorrentHash;
      // Hand the prefetch session to the replacement screen. Nulled here so
      // our dispose() — which runs right after pushReplacement — doesn't
      // cancel the session the next episode is about to play from.
      final handoffSessionId = prefetchSessionId;
      prefetchSessionId = null;
      AppLog.d(
        '[NextEpisodeProxy] handing off to player streaming=${streamingHash != null} '
        'hash=$streamingHash '
        'fileIdx=$_nextEpisodeStreamingFileIndex '
        'url=$_nextEpisodeStreamingProxyUrl '
        'session=$handoffSessionId',
      );
      // Navigate to next episode
      openReplacementPlayer(
        target,
        torrentHash: streamingHash,
        fileIndex: _nextEpisodeStreamingFileIndex,
        proxyUrl: _nextEpisodeStreamingProxyUrl,
        sessionId: handoffSessionId,
      );
    }
  }

  void minimizeNextEpisode() {
    setState(() => planner.minimizeOverlay());
  }

  void restoreNextEpisode() {
    setState(() => planner.restoreOverlay());
  }

  void consumeNextEpisodePrompt() {
    setState(() => planner.consumeOverlay());
  }

  void dismissNextPrefetch() {
    _nextPrefetchHideTimer?.cancel();
    if (!mounted) return;
    setState(() => nextPrefetch = null);
  }

  void setNextEpisodePrefetch({
    required StreamingStatus status,
    String? episodeCode,
    double? progress,
    String? message,
    int downloadRateBytesPerSec = 0,
  }) {
    if (!mounted) return;
    final firstAppearance = nextPrefetch == null;
    _nextPrefetchHideTimer?.cancel();
    setState(() {
      nextPrefetch = NextEpisodePrefetch(
        status: status,
        episodeCode: episodeCode ?? nextPrefetch?.episodeCode,
        progress: progress,
        message: message,
        downloadRateBytesPerSec: downloadRateBytesPerSec,
      );
    });
    if (firstAppearance) onUserInteraction();
    if (status == StreamingStatus.ready) {
      _nextPrefetchHideTimer = Timer(
        const Duration(seconds: 4),
        dismissNextPrefetch,
      );
    }
  }

  /// Overlay "Stream" button — prefetch and open the next episode as soon
  /// as the buffer is ready. Continue Watching On uses the same fetch with
  /// [playWhenReady] false so the current episode keeps playing.
  Future<void> onStreamNextEpisode() =>
      _prefetchNextEpisode(playWhenReady: true);

  /// Start a next-episode streaming session without making it the global
  /// active session (that would trip the nav safety-net into opening it).
  Future<void> _prefetchNextEpisode({required bool playWhenReady}) async {
    AppLog.d(
      '[StreamingService] Prefetch next episode playWhenReady=$playWhenReady',
    );
    final episode = nextEpisodeFromTmdb;
    AppLog.d(
      '[StreamingService] Episode: ${episode?.episodeCode}, IMDB: $_currentImdbId',
    );

    if (episode == null || _currentImdbId == null) {
      AppLog.w('[StreamingService] Missing episode or IMDB ID, canceling');
      if (playWhenReady) consumeNextEpisodePrompt();
      return;
    }

    final autoDownloadService = ref.read(autoDownloadServiceProvider);
    final settings = ref.read(settingsProvider);
    final quality =
        playingFile.quality ?? ref.read(autoDownloadProvider).defaultQuality;

    AppLog.d(
      '[StreamingService] Searching for torrent: S${episode.seasonNumber}E${episode.episodeNumber} quality: $quality',
    );

    if (playWhenReady) {
      consumeNextEpisodePrompt();
    }

    setNextEpisodePrefetch(
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
      setNextEpisodePrefetch(
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
          showName: playingFile.showName,
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
      setNextEpisodePrefetch(
        status: StreamingStatus.error,
        message: 'Failed to start stream',
        episodeCode: episode.episodeCode,
      );
      return;
    }

    // Track the show for future auto-downloads
    if (currentShowId != null) {
      // Not awaited: registering interest is bookkeeping, not something
      // the user waits on before the episode starts.
      unawaited(
        ref
            .read(autoDownloadProvider.notifier)
            .trackShow(
              showId: currentShowId!,
              imdbId: _currentImdbId,
              showName: playingFile.showName ?? '',
              season: episode.seasonNumber,
              episode: episode.episodeNumber,
              quality: torrent.quality,
            ),
      );
    }

    prefetchSessionId = session.id;
    setState(() {
      _nextEpisodeDownloadStarted = true;
      _downloadingEpisode = episode;
    });

    setNextEpisodePrefetch(
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
          setNextEpisodePrefetch(
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
            nextEpisode = videoFile;
            nextEpisodeFromTmdb = null; // Clear TMDB version
            _nextEpisodeStreamingTorrentHash = session.torrentHash;
            _nextEpisodeStreamingFileIndex = session.selectedFileIndex;
            _nextEpisodeStreamingProxyUrl = session.streamUrl;
          });
          _nextEpisodeSubscription?.cancel();
          _nextEpisodeSubscription = null;
          if (playWhenReady) {
            onPlayNextEpisode();
          } else {
            setNextEpisodePrefetch(
              status: StreamingStatus.ready,
              message: 'Next episode ready',
              episodeCode: episode.episodeCode,
              progress: session.bufferProgress,
            );
          }

        case StreamingState.error:
          setNextEpisodePrefetch(
            status: StreamingStatus.error,
            message: session.errorMessage ?? 'Streaming failed',
            episodeCode: episode.episodeCode,
          );
          _nextEpisodeSubscription?.cancel();
          _nextEpisodeSubscription = null;

        case StreamingState.cancelled:
        case StreamingState.idle:
          prefetchSessionId = null;
          dismissNextPrefetch();
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

  /// Cancel everything this mixin started. Called from the screen's
  /// `dispose()` in the position these five cancels already occupied, so the
  /// teardown order — which matters, the health monitor must stop before its
  /// sessions are cancelled — is unchanged.
  ///
  /// Deliberately not an override of `dispose()`: mixin `super` ordering is
  /// linearisation order, which is not visible at the call site.
  void disposeNextEpisodeController() {
    _positionSubscription?.cancel();
    _completedSubscription?.cancel();
    _autoDownloadSubscription?.cancel();
    _nextEpisodeSubscription?.cancel();
    _nextPrefetchHideTimer?.cancel();
  }
}
