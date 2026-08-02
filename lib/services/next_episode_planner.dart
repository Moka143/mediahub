import 'package:flutter/foundation.dart';

/// What the binge logic wants done at this playback position.
enum NextEpisodeAction {
  /// Nothing to do on this tick.
  none,

  /// Continue Watching is on for this show — hand straight off to the next
  /// episode without a countdown.
  autoPlay,

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

  bool _overlayVisible = false;
  bool _overlayDismissed = false;
  bool _autoPlayFired = false;
  bool _autoDownloadTriggered = false;

  bool get overlayVisible => _overlayVisible;
  bool get overlayDismissed => _overlayDismissed;
  bool get autoPlayFired => _autoPlayFired;
  bool get autoDownloadTriggered => _autoDownloadTriggered;

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
  /// [hasPlayableNextEpisode] means a real file (or a ready stream proxy) is
  /// in hand. [hasAnyNextEpisode] is looser — it includes an episode TMDB
  /// knows about but which isn't downloaded yet, which is enough to show the
  /// overlay (it offers a download) but not enough to auto-play.
  @visibleForTesting
  static NextEpisodeAction decideAction({
    required bool inTriggerWindow,
    required bool resumePromptVisible,
    required bool continueWatchingOn,
    required bool hasPlayableNextEpisode,
    required bool hasAnyNextEpisode,
    required bool overlayVisible,
    required bool overlayDismissed,
    required bool autoPlayFired,
  }) {
    // The resume prompt owns the screen while it's up — stacking a countdown
    // on top of "resume from 12:34?" would be two modal decisions at once.
    if (resumePromptVisible || !inTriggerWindow) return NextEpisodeAction.none;

    if (continueWatchingOn) {
      if (!autoPlayFired && hasPlayableNextEpisode) {
        return NextEpisodeAction.autoPlay;
      }
      // Deliberately does not fall through to the overlay. Flipping on
      // Continue Watching IS the consent to skip the prompt, so showing a
      // countdown card here — because the next episode happens to still be
      // buffering — would be a regression from what the user asked for.
      return NextEpisodeAction.none;
    }

    if (overlayDismissed || overlayVisible) return NextEpisodeAction.none;
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
    required bool hasPlayableNextEpisode,
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
      hasPlayableNextEpisode: hasPlayableNextEpisode,
      hasAnyNextEpisode: hasAnyNextEpisode,
      overlayVisible: _overlayVisible,
      overlayDismissed: _overlayDismissed,
      autoPlayFired: _autoPlayFired,
    );

    switch (action) {
      case NextEpisodeAction.autoPlay:
        _autoPlayFired = true;
      case NextEpisodeAction.showOverlay:
        _overlayVisible = true;
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

  /// Claim the auto-download one-shot immediately, ignoring the threshold.
  ///
  /// Used when the user flips Continue Watching on mid-episode: waiting for
  /// 70% would mean the download starts too late to be seamless. Returns
  /// false when a download is already in flight.
  bool claimAutoDownloadNow() {
    if (_autoDownloadTriggered) return false;
    _autoDownloadTriggered = true;
    return true;
  }

  /// User dismissed the countdown. Latches so it does not reappear for the
  /// rest of this episode.
  void dismissOverlay() {
    _overlayVisible = false;
    _overlayDismissed = true;
  }
}
