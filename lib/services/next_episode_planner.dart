import 'package:flutter/foundation.dart';

import '../models/local_media_file.dart';
import '../utils/media_names.dart';

/// What the binge logic wants done at this playback position.
enum NextEpisodeAction {
  /// Nothing to do on this tick.
  none,

  /// Surface the "Up Next" countdown overlay.
  showOverlay,
}

/// Decides *when* to offer the next episode, and holds the one-shot guards
/// that keep those decisions from firing twice.
///
/// Extracted from `video_player_screen.dart`, where this lived as four
/// interacting booleans (`_showNextEpisodeOverlay`,
/// `_nextEpisodeOverlayDismissed`, `_autoNextEpisodeFired`,
/// `_autoDownloadTriggered`) read and written across two position
/// subscriptions and three async callbacks. Every rule below was previously
/// an `if` buried in a stream listener, so none of it could be tested without
/// a real `Player`, a real qBittorrent and a real TMDB round-trip.
///
/// **What this deliberately does NOT own.** Unlike `PlaybackHealthMonitor`,
/// which could be made fully self-contained, the next-episode flow's side
/// effects are irreducibly screen-coupled: resolving the show on TMDB,
/// rescanning the library, and `pushReplacement`-ing a new player route all
/// need `Ref` and `BuildContext`. Pulling those in here would mean a
/// constructor full of callbacks that just relay back to the widget — more
/// indirection for no more testability. So this owns the decisions and the
/// guards; the screen owns the subscriptions and the I/O.
class NextEpisodePlanner {
  NextEpisodePlanner({required this.bingeEnabled});

  /// Master switch from settings. When false, [evaluatePosition] never
  /// returns anything but [NextEpisodeAction.none].
  final bool bingeEnabled;

  /// Show the prompt once playback is inside the final tenth of the episode.
  ///
  /// Scales with duration — ~4 min on a 45-min episode, ~6 min on an
  /// hour-long one — which lands in the credits window where users actually
  /// want it. A fixed number of seconds would be too early on long content
  /// and too late on short.
  static const double finalStretchRatio = 0.90;

  bool _overlayOffered = false;
  bool _overlayMinimized = false;
  bool _overlayConsumed = false;
  bool _autoDownloadTriggered = false;

  /// The prompt has been offered this episode (expanded or minimized).
  /// Only tests need to see the latch directly; the screen reads
  /// [overlayActive].
  @visibleForTesting
  bool get overlayOffered => _overlayOffered;

  bool get overlayMinimized => _overlayMinimized;

  /// Prompt is on screen — chip or expanded row — and has not been consumed
  /// by Play / Stream.
  bool get overlayActive => _overlayOffered && !_overlayConsumed;

  /// Whether [claimAutoDownloadAtThreshold] has fired this episode. For
  /// tests; callers act on that method's return value.
  @visibleForTesting
  bool get autoDownloadTriggered => _autoDownloadTriggered;

  // ---------------------------------------------------------------------
  // Which episode comes next, and where a finished copy of it is
  // ---------------------------------------------------------------------

  /// The episodes that could come after [season]×[episode], most likely
  /// first.
  ///
  /// TMDB is authoritative: when it named the next episode ([fromTmdb]),
  /// that is the only candidate. "Next in this season, then the first of the
  /// next" is the fallback for when TMDB could not answer — a show whose
  /// numbering does not follow that shape used to jump to the wrong episode
  /// or to none at all.
  static List<({int season, int episode})> nextEpisodeCandidates({
    ({int season, int episode})? fromTmdb,
    int? season,
    int? episode,
  }) {
    if (fromTmdb != null) return [fromTmdb];
    if (season == null || episode == null) return const [];
    return [
      (season: season, episode: episode + 1),
      (season: season + 1, episode: 1),
    ];
  }

  /// The library files that could be the next episode of [showName], in
  /// [candidates] order — still to be checked for being *finished* on disk.
  ///
  /// The show must be the same show ([titlesMatch]: "You" is not "Young
  /// Sheldon"), and the file playing now is never its own next episode.
  static List<LocalMediaFile> nextEpisodeFilesIn(
    List<LocalMediaFile> library, {
    required String showName,
    required String playingPath,
    required List<({int season, int episode})> candidates,
  }) => [
    for (final candidate in candidates)
      for (final file in library)
        if (file.seasonNumber == candidate.season &&
            file.episodeNumber == candidate.episode &&
            file.path != playingPath &&
            file.showName != null &&
            titlesMatch(file.showName!, showName))
          file,
  ];

  // ---------------------------------------------------------------------
  // Pure decision logic — no player, no Ref, testable with plain numbers
  // ---------------------------------------------------------------------

  /// Whether playback has reached the point where the next episode should be
  /// offered.
  ///
  /// Fires on whichever comes first: the final [finalStretchRatio] of the
  /// episode, or [countdownSeconds] remaining — the latter being the fallback
  /// for very short content where 10% is only a couple of seconds.
  ///
  /// Content that has already ended is excluded: `remaining <= 0` belongs to
  /// the playback-completion watcher, which hands off directly rather than
  /// showing a countdown for an episode that is already over.
  @visibleForTesting
  static bool isInTriggerWindow({
    required Duration position,
    required Duration duration,
    required int countdownSeconds,
  }) {
    if (duration.inMilliseconds <= 0) return false;
    final remaining = duration - position;
    if (remaining.inSeconds <= 0) return false;

    final positionRatio = position.inMilliseconds / duration.inMilliseconds;
    return positionRatio >= finalStretchRatio ||
        remaining.inSeconds <= countdownSeconds;
  }

  /// Map the current situation onto an action.
  ///
  /// [hasAnyNextEpisode] includes an episode TMDB knows about but which
  /// isn't downloaded yet — enough to show the overlay (it offers a
  /// download). Continue Watching On never overlays; it prefetches in
  /// the background and hands off when playback completes.
  ///
  /// Once offered, later ticks stay quiet even if playback leaves and
  /// re-enters the trigger window. Minimize / restore are UI state on
  /// that same offer — they do not re-fire [NextEpisodeAction.showOverlay].
  @visibleForTesting
  static NextEpisodeAction decideAction({
    required bool inTriggerWindow,
    required bool resumePromptVisible,
    required bool continueWatchingOn,
    required bool hasAnyNextEpisode,
    required bool overlayOffered,
  }) {
    // The resume prompt owns the screen while it's up — stacking a countdown
    // on top of "resume from 12:34?" would be two modal decisions at once.
    if (resumePromptVisible || !inTriggerWindow) return NextEpisodeAction.none;

    if (continueWatchingOn) {
      // On prefetches in the background (progress threshold) and hands
      // off when the current episode *completes* — not here in the
      // credits window, and not via the overlay. Jumping at 90% felt
      // like the next episode taking over mid-watch.
      return NextEpisodeAction.none;
    }

    if (overlayOffered) return NextEpisodeAction.none;
    if (!hasAnyNextEpisode) return NextEpisodeAction.none;
    return NextEpisodeAction.showOverlay;
  }

  /// Whether the next episode's download should be kicked off now.
  ///
  /// Separate from the overlay decision and fires much earlier (default 70%
  /// vs 90%), so the download has time to buffer before the episode ends.
  @visibleForTesting
  static bool shouldTriggerAutoDownload({
    required bool gateOpen,
    required bool alreadyTriggered,
    required Duration position,
    required Duration duration,
    required double threshold,
  }) {
    if (alreadyTriggered || !gateOpen) return false;
    if (duration.inMilliseconds <= 0) return false;
    return position.inMilliseconds / duration.inMilliseconds >= threshold;
  }

  // ---------------------------------------------------------------------
  // Stateful entry points — apply the decision, then latch its guard
  // ---------------------------------------------------------------------

  /// Evaluate one position tick and latch whichever one-shot guard the
  /// resulting action consumes, so the caller can act without also having to
  /// remember to set a flag.
  NextEpisodeAction evaluatePosition({
    required Duration position,
    required Duration duration,
    required int countdownSeconds,
    required bool resumePromptVisible,
    required bool continueWatchingOn,
    required bool hasAnyNextEpisode,
  }) {
    if (!bingeEnabled) return NextEpisodeAction.none;

    final action = decideAction(
      inTriggerWindow: isInTriggerWindow(
        position: position,
        duration: duration,
        countdownSeconds: countdownSeconds,
      ),
      resumePromptVisible: resumePromptVisible,
      continueWatchingOn: continueWatchingOn,
      hasAnyNextEpisode: hasAnyNextEpisode,
      overlayOffered: _overlayOffered,
    );

    switch (action) {
      case NextEpisodeAction.showOverlay:
        _overlayOffered = true;
        _overlayMinimized = false;
      case NextEpisodeAction.none:
        break;
    }
    return action;
  }

  /// Claim the auto-download one-shot if the progress threshold has been
  /// crossed. Returns true exactly once per session.
  bool claimAutoDownloadAtThreshold({
    required bool gateOpen,
    required Duration position,
    required Duration duration,
    required double threshold,
  }) {
    final should = shouldTriggerAutoDownload(
      gateOpen: gateOpen,
      alreadyTriggered: _autoDownloadTriggered,
      position: position,
      duration: duration,
      threshold: threshold,
    );
    if (should) _autoDownloadTriggered = true;
    return should;
  }

  /// Collapse the prompt to a restore chip. Stays available for the rest
  /// of the episode, including after playback leaves the trigger window.
  void minimizeOverlay() {
    if (!_overlayOffered || _overlayConsumed) return;
    _overlayMinimized = true;
  }

  /// Expand the prompt again. Safe to call after the trigger percentage
  /// has already passed — the offer is latched for the episode, not the
  /// window.
  void restoreOverlay() {
    if (!_overlayOffered || _overlayConsumed) return;
    _overlayMinimized = false;
  }

  /// Play / Stream took over. The prompt leaves and does not return.
  void consumeOverlay() {
    _overlayConsumed = true;
    _overlayMinimized = false;
  }
}
