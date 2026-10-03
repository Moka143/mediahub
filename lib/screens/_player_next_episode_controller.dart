import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/episode.dart';
import '../models/local_media_file.dart';
import '../models/stream_request.dart';
import '../models/streaming_status.dart';
import '../providers/auto_download_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/subtitle_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/app_logger.dart';
import '../services/library_actions.dart';
import '../services/next_episode_planner.dart';
import '../services/streaming_service.dart';
import '../utils/media_names.dart';
import '../widgets/player/player_error_overlay.dart';

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
/// the screen keeps reading [nextEpisode] and [nextPrefetch] as plain fields.
/// Same shape as `DetailsPlaybackController`, which did this for the details
/// screens.
///
/// The split with [NextEpisodePlanner] is unchanged: the planner owns the
/// *decisions* — when to offer, the one-shot guards — and is unit-tested;
/// this mixin owns the *side effects* — subscriptions, TMDB, the engine,
/// navigation — which need a live stack.
///
/// **Every await here can outlive the screen.** The TMDB lookups take
/// seconds and the user can close the player during any of them. A `ref`
/// used after that throws, and an uncaught async error used to quit the
/// app — closing the player on the resume prompt within a second of opening
/// an episode did exactly that. So: providers are read into locals before
/// the first await, and `mounted` is checked after every one.
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

  /// Show IMDB id the screen was opened with, when the caller knew it.
  String? get openedWithShowImdbId;

  /// Reset the screen's auto-hiding chrome. Called when the prefetch pill
  /// first appears, so it is not born invisible.
  void onUserInteraction();

  /// Clear the current-episode health-monitor chip.
  void dismissStreamingStatus();

  /// Replace this route with a player for [file].
  ///
  /// [session] is the stream to hand over — the replacement takes ownership
  /// of it — and is null on the from-disk path, which has none.
  ///
  /// Navigation is the widget's job, not this mixin's: building a
  /// `VideoPlayerScreen` here would make the two files import each other, and
  /// `BuildContext` belongs on the screen side of the seam.
  void openReplacementPlayer(
    LocalMediaFile file, {
    StreamingSession? session,
    String? showImdbId,
  });

  // ── Owned state ────────────────────────────────────────────────────────

  LocalMediaFile? nextEpisode;

  Episode? nextEpisodeFromTmdb; // Next episode from TMDB (not downloaded yet)

  int? currentShowId;

  String? _currentImdbId;

  StreamSubscription<Duration>? _positionSubscription;

  StreamSubscription<bool>? _completedSubscription;

  StreamSubscription<Duration>? _autoDownloadSubscription;

  /// Subscription to the next-episode [StreamingService] session. Cancelled
  /// on any terminal state and in dispose.
  StreamSubscription<StreamingSession>? _nextEpisodeSubscription;

  /// The prefetched next episode's session, once it is ready. Handed to the
  /// replacement player with [nextEpisode], so the next episode reads
  /// through the stream's proxy instead of the half-written file on disk.
  StreamingSession? _nextEpisodeSession;

  /// The episode a prefetch session was started for.
  Episode? _prefetchEpisode;

  /// A prefetch is between "find a source" and "session started", when
  /// [prefetchSessionId] is not known yet.
  bool _prefetchStarting = false;

  /// Play the next episode the moment its prefetch is ready — set by the Up
  /// Next card's Stream, and by this episode ending while the prefetch is
  /// still buffering.
  bool _playPrefetchWhenReady = false;

  /// [onPlayNextEpisode] is under way. The countdown running out and a
  /// click on Play can land together, and each used to replace the route.
  bool _handingOff = false;

  NextEpisodePrefetch? nextPrefetch;

  Timer? _nextPrefetchHideTimer;

  /// The prefetch session this screen owns and must cancel on dispose,
  /// unless it hands it to the next episode's screen first.
  String? prefetchSessionId;

  /// How long the "Next episode ready" tick stays beside the pill.
  static const Duration _readyPillDuration = Duration(seconds: 4);

  /// After a prefetch's session ends, how long to give the library to notice
  /// the finished file before looking for it.
  static const Duration _librarySettleDelay = Duration(seconds: 2);

  /// Fallback quality when neither the playing file nor the settings name
  /// one.
  static const String _fallbackQuality = '1080p';

  /// Whether this screen is still the one on top. During a hand-off the
  /// outgoing player stays mounted under the incoming one for the length of
  /// the route transition, and must not write app-wide state — the subtitle
  /// context — that the incoming one has just reset for its own file.
  bool get _isFrontmost =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  /// Resolve the show, its IMDB id and the next episode, and attach the Up
  /// Next watcher.
  ///
  /// The show is resolved whether or not binge watching is on. It used to
  /// return first thing when it was off, and the show id and IMDB id are
  /// what the Next episode pill, the OpenSubtitles lookup for a Library file
  /// and linking watch progress to the show all depend on. Binge watching
  /// only gates what it promises: the Up Next card (via [planner]) and
  /// fetching the next episode ahead.
  Future<void> setupNextEpisodeWatcher() async {
    _currentImdbId ??= openedWithShowImdbId;
    try {
      if (planner.bingeEnabled) _attachUpNextWatcher();
      await _checkTmdbForNextEpisode();
      if (!mounted || !planner.bingeEnabled) return;
      await _findNextEpisodeOnDisk();
    } catch (e) {
      AppLog.e('[NextEpisode] lookup failed: $e');
    }
  }

  /// Watch the position for the Up Next window.
  ///
  /// Attached up front — before we know whether there is a next episode. If
  /// we waited for TMDB and the library (a network round trip, which can
  /// outlast the user crossing the countdown threshold) we would miss the
  /// window entirely. The prefetch can also surface a next episode much
  /// later, and the card should fire then too. So: always attach, and check
  /// [hasNextEpisode] on each tick.
  void _attachUpNextWatcher() {
    final player = ref.read(playerProvider);
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
  }

  bool hasNextEpisode() => nextEpisode != null || nextEpisodeFromTmdb != null;

  /// Resolve the show on TMDB — its id, its IMDB id, and the episode after
  /// this one.
  Future<void> _checkTmdbForNextEpisode() async {
    final file = playingFile;
    final showName = file.showName;
    final season = file.seasonNumber;
    final episode = file.episodeNumber;

    if (showName == null || season == null || episode == null) {
      AppLog.d('[NextEpisode] no show info on ${file.fileName}, skipping TMDB');
      return;
    }

    // Everything this needs after its first await, read while it is safe.
    final tmdbService = ref.read(tmdbApiServiceProvider);
    final autoDownloadService = ref.read(autoDownloadServiceProvider);
    final progress = ref.read(watchProgressProvider.notifier);
    final subtitles = ref.read(subtitleContextProvider.notifier);

    try {
      final shows = await tmdbService.searchShows(showName);
      if (!mounted || shows.isEmpty) return;

      // Prefer the result whose title is this show's, not merely the most
      // popular match for the words in it.
      final show = shows.firstWhere(
        (s) => titlesMatch(s.name, showName),
        orElse: () => shows.first,
      );
      // setState rather than bare assign — the controls read `currentShowId`
      // to decide whether to show the per-show Next episode pill.
      setState(() => currentShowId = show.id);
      unawaited(progress.attachShowId(file.path, show.id));

      // Full show details with the IMDB id (append_to_response=external_ids).
      final showDetails = await tmdbService.getShowDetailsWithImdb(show.id);
      if (!mounted) return;
      _currentImdbId = showDetails.imdbId ?? openedWithShowImdbId;

      final imdbId = _currentImdbId;
      if (imdbId != null && _isFrontmost) {
        subtitles.setSeriesContext(
          imdbId: imdbId,
          season: season,
          episode: episode,
        );
      }

      final result = await autoDownloadService.getNextEpisode(
        showId: show.id,
        currentSeason: season,
        currentEpisode: episode,
      );
      if (!mounted) return;
      AppLog.d(
        '[NextEpisode] TMDB says next is '
        '${result.nextEpisode?.episodeCode ?? "none"}'
        '${result.hasAired ? '' : ' (not aired yet)'}',
      );
      // An episode that has not aired has no torrent yet: offering it would
      // put up an Up Next card (and start a prefetch) that can only end in
      // "No torrent found".
      setState(
        () => nextEpisodeFromTmdb = result.hasAired ? result.nextEpisode : null,
      );
    } catch (e) {
      AppLog.e('[NextEpisode] TMDB lookup failed: $e');
    }
  }

  /// Use a finished copy of the next episode from the library, if there is
  /// one, in place of TMDB's "you'd have to stream it".
  Future<void> _findNextEpisodeOnDisk() async {
    final match = await _finishedEpisodeOnDisk(_nextEpisodeCandidates());
    if (!mounted || match == null || nextEpisode != null) return;
    AppLog.d('[NextEpisode] next episode is on disk: ${match.fileName}');
    setState(() {
      nextEpisode = match;
      nextEpisodeFromTmdb = null;
    });
  }

  /// Which episodes could come next, most likely first — see
  /// [NextEpisodePlanner.nextEpisodeCandidates].
  List<({int season, int episode})> _nextEpisodeCandidates() {
    final fromTmdb = nextEpisodeFromTmdb;
    return NextEpisodePlanner.nextEpisodeCandidates(
      fromTmdb: fromTmdb == null
          ? null
          : (season: fromTmdb.seasonNumber, episode: fromTmdb.episodeNumber),
      season: playingFile.seasonNumber,
      episode: playingFile.episodeNumber,
    );
  }

  /// The first of [candidates] the library holds a *finished* copy of.
  ///
  /// Reads the library the app has already scanned rather than walking the
  /// download folder again — this ran a full recursive scan every time an
  /// episode opened.
  ///
  /// "Finished" is the point: the engine pre-allocates a file at its full
  /// size, so a download that is 1% done already *exists*. An existence
  /// check handed mpv a file of zeros, with no proxy in front of it to hold
  /// back the reads — see [isFileCompleteOnDisk].
  Future<LocalMediaFile?> _finishedEpisodeOnDisk(
    List<({int season, int episode})> candidates,
  ) async {
    final showName = playingFile.showName;
    if (showName == null || candidates.isEmpty) return null;

    final library = await ref.read(localMediaFilesProvider.future);
    final files = NextEpisodePlanner.nextEpisodeFilesIn(
      library,
      showName: showName,
      playingPath: playingFile.path,
      candidates: candidates,
    );
    for (final file in files) {
      // `isFileCompleteOnDisk` reads `ref` before its own await.
      if (!mounted) return null;
      if (await isFileCompleteOnDisk(ref, file)) return file;
    }
    return null;
  }

  /// Called when the user switches the Next episode pill to On for this
  /// show. Fetches the next episode only if we're already past the progress
  /// threshold (so turning On during credits still works). Earlier than
  /// that, the position watcher starts the fetch at the threshold — never by
  /// jumping to the next episode.
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
        '[NextEpisodeMode] On — waiting for '
        '${(state.progressThreshold * 100).toInt()}% before fetching',
      );
      return;
    }
    AppLog.d('[NextEpisodeMode] On past the threshold — fetching now');
    unawaited(_triggerAutoDownload());
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
    const decisionLogInterval = Duration(seconds: 5);

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
        unawaited(_triggerAutoDownload());
        return;
      }

      // Diagnostic only: we're past the threshold but the gate is shut.
      // Throttled so a closed gate doesn't log on every position event.
      if (active || duration.inMilliseconds <= 0) return;
      final progress = position.inMilliseconds / duration.inMilliseconds;
      if (progress < state.progressThreshold) return;
      final now = DateTime.now();
      if (now.difference(lastDecisionLogAt) < decisionLogInterval) return;
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

    if (showName == null || season == null || episode == null) return;

    // Read now: the lookups below can outlive the screen, and the download
    // itself is still wanted if they do — the user watched past the
    // threshold.
    final tmdbService = ref.read(tmdbApiServiceProvider);
    final autoDownload = ref.read(autoDownloadProvider.notifier);
    final progress = ref.read(watchProgressProvider.notifier);
    final state = ref.read(autoDownloadProvider);
    final quality = file.quality ?? state.defaultQuality;

    try {
      // Prefer the show id + imdb id we already resolved in
      // `_checkTmdbForNextEpisode` (which uses `getShowDetailsWithImdb`).
      // `getShowDetails` doesn't request external ids, so the older fallback
      // here always came back without an IMDB id and the torrent search,
      // which needs one, bailed out one step later.
      var showId = currentShowId;
      var imdbId = _currentImdbId;

      if (showId == null || imdbId == null) {
        final shows = await tmdbService.searchShows(showName);
        if (shows.isEmpty) {
          AppLog.d('[AutoDownload] TMDB returned no shows for $showName');
          return;
        }
        final show = shows.firstWhere(
          (s) => titlesMatch(s.name, showName),
          orElse: () => shows.first,
        );
        final details = await tmdbService.getShowDetailsWithImdb(show.id);
        showId = show.id;
        imdbId = details.imdbId;
        if (mounted) {
          setState(() {
            currentShowId = showId;
            _currentImdbId = imdbId;
          });
        }
        unawaited(progress.attachShowId(file.path, show.id));
      }

      // Next episode On fetches the next episode through StreamingService
      // so the hand-off already has a proxy URL — as a *background* session.
      // The Up Next card's Stream is the play-now path; reusing it here used
      // to steal `activeSessionId`, and the nav safety-net would open episode
      // N+1 on top of episode N. Only while binge watching is on.
      final cwOverride = state.showAutoDownloadOverrides[showId];
      if (cwOverride == true &&
          nextEpisodeFromTmdb != null &&
          planner.bingeEnabled &&
          mounted) {
        AppLog.d('[AutoDownload] Next episode On → prefetch (show $showId)');
        await _prefetchNextEpisode(playWhenReady: false);
        return;
      }

      AppLog.d(
        '[AutoDownload] → onWatchProgress showId=$showId imdbId=$imdbId',
      );

      // Not awaited: this reaches out to the indexer and the engine.
      // Playback must not wait on it.
      unawaited(
        autoDownload.onWatchProgress(
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
  /// Only Next episode **On** jumps automatically here. Auto uses the Up
  /// Next card (and its countdown); Off does nothing.
  void setupPlaybackCompletionWatcher() {
    final player = ref.read(playerProvider);

    _completedSubscription = player.stream.completed.listen((completed) {
      if (!completed || !mounted) return;

      final cwOverride = currentShowId == null
          ? null
          : ref
                .read(autoDownloadProvider)
                .showAutoDownloadOverrides[currentShowId];
      if (cwOverride != true) return;

      AppLog.d('[NextEpisodeMode] Playback completed — handing off');
      unawaited(_handOffAtEnd());
    });
  }

  /// This episode has ended with Next episode On: move on to the next one.
  Future<void> _handOffAtEnd() async {
    if (nextEpisode != null) {
      await onPlayNextEpisode();
      return;
    }

    // A prefetch is still buffering. Hand its session over once it is
    // ready. Opening its file from disk instead meant reading the
    // half-written download with no proxy in front of it — and our own
    // dispose then cancelled the prefetch that file was coming from.
    if (_prefetchStarting || prefetchSessionId != null) {
      _playPrefetchWhenReady = true;
      setNextEpisodePrefetch(
        status: StreamingStatus.buffering,
        episodeCode: _prefetchEpisode?.episodeCode,
        progress: nextPrefetch?.progress,
      );
      return;
    }

    // A prefetch that failed has nothing on its way to disk; look for a
    // finished copy of the next episode from anywhere else.
    final prefetchFailed = nextPrefetch?.status == StreamingStatus.error;
    await _playNextEpisodeFromDisk(
      target: prefetchFailed ? null : _prefetchEpisode,
    );
  }

  /// Find the next episode on disk and hand the player over to it.
  ///
  /// [target] is the episode a prefetch was fetching, when there was one;
  /// its session has ended, and the library is refreshed first so a file
  /// that finished seconds ago is seen. Otherwise the candidates are TMDB's
  /// answer, or "next in this season, then first of the next".
  Future<void> _playNextEpisodeFromDisk({Episode? target}) async {
    final playerService = ref.read(playerServiceProvider);
    final candidates = target != null
        ? [(season: target.seasonNumber, episode: target.episodeNumber)]
        : _nextEpisodeCandidates();
    if (candidates.isEmpty) return;

    if (target != null) {
      // The file may have landed seconds ago — let the library catch up.
      refreshLocalMedia(ref);
      await Future<void>.delayed(_librarySettleDelay);
      if (!mounted) return;
    }

    final match = await _finishedEpisodeOnDisk(candidates);
    if (!mounted) return;

    if (match != null) {
      AppLog.d('[NextEpisode] Playing ${match.fileName} from disk');
      dismissStreamingStatus();
      dismissNextPrefetch();
      await playerService.stop();
      if (!mounted) return;
      openReplacementPlayer(match, showImdbId: _currentImdbId);
      return;
    }

    if (target != null) {
      AppLog.w('[NextEpisode] ${target.episodeCode} is not finished yet');
      setNextEpisodePrefetch(
        status: StreamingStatus.buffering,
        message: 'still downloading — play it from Library when it finishes',
        episodeCode: target.episodeCode,
      );
    }
  }

  /// Open the next episode — the Up Next card's Play, the countdown running
  /// out, and the hand-off at the end with Next episode On.
  Future<void> onPlayNextEpisode() async {
    final target = nextEpisode;
    if (target == null || !mounted || _handingOff) return;
    _handingOff = true;

    unawaited(_positionSubscription?.cancel());
    _positionSubscription = null;
    dismissStreamingStatus();
    dismissNextPrefetch();
    consumeNextEpisodePrompt();

    final playerService = ref.read(playerServiceProvider);
    final session = _nextEpisodeSession;
    final showImdbId = _currentImdbId ?? openedWithShowImdbId;

    await playerService.stop();
    // If the player closed during the stop, our dispose has already
    // cancelled the prefetch session — there is no one to hand it to.
    if (!mounted) return;

    if (session != null) {
      // Ownership moves to the replacement screen. Nulled so our dispose —
      // which runs once the replacement's route transition ends — doesn't
      // cancel the session the next episode is playing from.
      prefetchSessionId = null;
    }
    AppLog.d(
      '[NextEpisode] handing off ${target.fileName} '
      'session=${session?.id} url=${session?.streamUrl}',
    );
    openReplacementPlayer(target, session: session, showImdbId: showImdbId);
  }

  void minimizeNextEpisode() {
    if (!mounted) return;
    setState(() => planner.minimizeOverlay());
  }

  void restoreNextEpisode() {
    if (!mounted) return;
    setState(() => planner.restoreOverlay());
  }

  void consumeNextEpisodePrompt() {
    if (!mounted) return;
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
      _nextPrefetchHideTimer = Timer(_readyPillDuration, dismissNextPrefetch);
    }
  }

  /// Up Next card "Stream" — fetch the next episode and open it as soon as
  /// it is ready. Next episode On uses the same fetch with [playWhenReady]
  /// false so the current episode keeps playing.
  Future<void> onStreamNextEpisode() =>
      _prefetchNextEpisode(playWhenReady: true);

  /// Start a next-episode streaming session without making it the global
  /// active session (that would trip the nav safety-net into opening it).
  Future<void> _prefetchNextEpisode({required bool playWhenReady}) async {
    if (!mounted || !planner.bingeEnabled) return;

    if (playWhenReady) {
      consumeNextEpisodePrompt();
      _playPrefetchWhenReady = true;
    }

    // One fetch per episode. A second request — the card's Stream while
    // Next episode On is already fetching, or the reverse — joins the one in
    // flight. It used to start a second session and overwrite
    // [prefetchSessionId], and the first was never cancelled.
    if (_nextEpisodeSession != null && nextEpisode != null) {
      if (playWhenReady) await onPlayNextEpisode();
      return;
    }
    if (_prefetchStarting || prefetchSessionId != null) {
      if (playWhenReady) {
        setNextEpisodePrefetch(
          status: nextPrefetch?.status ?? StreamingStatus.buffering,
          progress: nextPrefetch?.progress,
          episodeCode: _prefetchEpisode?.episodeCode,
        );
      }
      return;
    }

    final episode = nextEpisodeFromTmdb;
    final imdbId = _currentImdbId;
    if (episode == null || imdbId == null) {
      AppLog.w('[NextEpisode] no episode or IMDB id to fetch — skipping');
      if (playWhenReady) {
        setNextEpisodePrefetch(
          status: StreamingStatus.error,
          message: "Couldn't find the next episode to stream",
        );
      }
      return;
    }

    // Read now: everything below happens across awaits.
    final autoDownloadService = ref.read(autoDownloadServiceProvider);
    final sessions = ref.read(streamingSessionsProvider.notifier);
    final autoDownload = ref.read(autoDownloadProvider.notifier);
    final savePath = ref.read(settingsProvider).defaultSavePath;
    final quality =
        playingFile.quality ?? ref.read(autoDownloadProvider).defaultQuality;
    final showName = playingFile.showName;

    _prefetchStarting = true;
    _prefetchEpisode = episode;
    setNextEpisodePrefetch(
      status: StreamingStatus.searching,
      episodeCode: episode.episodeCode,
    );

    try {
      final torrent = await autoDownloadService.findTorrentForEpisode(
        imdbId: imdbId,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
        preferredQuality: quality.isEmpty ? _fallbackQuality : quality,
      );
      if (!mounted) return;

      if (torrent == null) {
        setNextEpisodePrefetch(
          status: StreamingStatus.error,
          message: 'No source found for ${episode.episodeCode}',
          episodeCode: episode.episodeCode,
        );
        return;
      }
      AppLog.d('[NextEpisode] source: ${torrent.title}');

      // Route through StreamingService rather than adding the torrent here.
      // This path used to call AutoDownloadService.downloadNextEpisode and
      // then re-implement the whole readiness workflow — file selection, the
      // buffer threshold, the on-disk file lookup and the proxy standup — in
      // this screen. Two copies meant two behaviours: notably the local copy
      // added torrents with firstLastPiecePrio: true, which StreamingService
      // deliberately sets to false because prioritising the LAST piece
      // breaks the strict in-order delivery sequential mode exists to
      // provide.
      final session = await sessions.startStreamingRequest(
        request: StreamRequest.fromEztv(torrent),
        showImdbId: imdbId,
        showName: showName,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
        episodeCode: episode.episodeCode,
        savePath: savePath,
        makeActive: false,
        // Competing with the current episode for disk/peers — a 10-minute
        // projected wait is normal. Aborting would freeze the pill on
        // "too slow" and stop progress updates.
        allowSlowBuffer: !playWhenReady,
      );

      if (!mounted) {
        // The player closed while the stream was starting. Nothing else
        // knows this session exists: its 2 s poll — and, on a downloader
        // engine, its proxy — would have run until the app quit.
        if (session != null) unawaited(sessions.cancelSession(session.id));
        return;
      }

      if (session == null) {
        setNextEpisodePrefetch(
          status: StreamingStatus.error,
          message: "Couldn't start ${episode.episodeCode}",
          episodeCode: episode.episodeCode,
        );
        return;
      }

      prefetchSessionId = session.id;

      // Track the show for future auto-downloads. Not awaited: registering
      // interest is bookkeeping, not something the user waits on.
      final showId = currentShowId;
      if (showId != null) {
        unawaited(
          autoDownload.trackShow(
            showId: showId,
            imdbId: imdbId,
            showName: showName ?? '',
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            quality: torrent.quality,
          ),
        );
      }

      setNextEpisodePrefetch(
        status: StreamingStatus.buffering,
        episodeCode: episode.episodeCode,
        progress: 0.0,
      );
      _monitorNextEpisodeStream(session.id, episode);
    } catch (e) {
      AppLog.e('[NextEpisode] prefetch failed: $e');
      setNextEpisodePrefetch(
        status: StreamingStatus.error,
        message: "Couldn't start ${episode.episodeCode}",
        episodeCode: episode.episodeCode,
      );
    } finally {
      _prefetchStarting = false;
    }
  }

  /// Mirror a next-episode [StreamingService] session into the pill, and
  /// keep the session when it turns ready.
  ///
  /// This used to be a hand-rolled 10-minute poll loop that re-derived file
  /// selection, the buffer threshold, the on-disk path and the proxy — all
  /// of which `StreamingService` already does for the primary playback path.
  /// Subscribing to the session means one implementation, and the session
  /// (not this screen) owns the proxy's lifetime, so it correctly survives
  /// the `pushReplacement` that pops us before the next screen mounts.
  void _monitorNextEpisodeStream(String sessionId, Episode episode) {
    unawaited(_nextEpisodeSubscription?.cancel());
    final service = ref.read(streamingServiceProvider);

    void stopListening() {
      unawaited(_nextEpisodeSubscription?.cancel());
      _nextEpisodeSubscription = null;
    }

    void apply(StreamingSession session) {
      if (!mounted) return;

      switch (session.state) {
        case StreamingState.addingTorrent:
        case StreamingState.selectingFiles:
        case StreamingState.buffering:
          setNextEpisodePrefetch(
            status: StreamingStatus.buffering,
            episodeCode: episode.episodeCode,
            progress: session.bufferProgress,
            downloadRateBytesPerSec: session.downloadRateBytesPerSec,
          );

        case StreamingState.ready:
        case StreamingState.playing:
          final videoFile = session.videoFile;
          if (videoFile == null || _nextEpisodeSession?.id == session.id) {
            return;
          }
          setState(() {
            nextEpisode = videoFile;
            nextEpisodeFromTmdb = null; // Clear TMDB version
            _nextEpisodeSession = session;
          });
          stopListening();
          if (_playPrefetchWhenReady) {
            unawaited(onPlayNextEpisode());
          } else {
            setNextEpisodePrefetch(
              status: StreamingStatus.ready,
              episodeCode: episode.episodeCode,
              progress: session.bufferProgress,
            );
          }

        case StreamingState.error:
          setNextEpisodePrefetch(
            status: StreamingStatus.error,
            message:
                presentableStreamError(session.errorMessage) ??
                "Couldn't stream the next episode",
            episodeCode: episode.episodeCode,
          );
          stopListening();
          // Nothing more will come of it: release it now rather than at
          // dispose, so the end of this episode doesn't wait on it.
          if (prefetchSessionId == session.id) {
            prefetchSessionId = null;
            unawaited(
              ref
                  .read(streamingSessionsProvider.notifier)
                  .cancelSession(session.id),
            );
          }

        case StreamingState.cancelled:
        case StreamingState.idle:
          prefetchSessionId = null;
          dismissNextPrefetch();
          stopListening();
      }
    }

    // Broadcast streams don't replay — apply the snapshot we already have
    // so the pill isn't stuck on "finding a source" until the next 2 s poll.
    final current = service.getSession(sessionId);
    if (current != null) {
      apply(current);
      if (current.isReady || !current.isActive) return;
    }
    if (!mounted) return;

    _nextEpisodeSubscription = service
        .getSessionStream(sessionId)
        ?.listen(apply);
  }

  /// Cancel everything this mixin started. Called from the screen's
  /// `dispose()` in the position these cancels already occupied, so the
  /// teardown order — which matters, the health monitor must stop before its
  /// sessions are cancelled — is unchanged.
  ///
  /// Deliberately not an override of `dispose()`: mixin `super` ordering is
  /// linearisation order, which is not visible at the call site.
  void disposeNextEpisodeController() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_completedSubscription?.cancel());
    unawaited(_autoDownloadSubscription?.cancel());
    unawaited(_nextEpisodeSubscription?.cancel());
    _nextPrefetchHideTimer?.cancel();
  }
}
