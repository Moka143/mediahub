import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_torrent_client/services/next_episode_planner.dart';

/// A 45-minute episode — the shape most of these rules were tuned for.
const _episode = Duration(minutes: 45);

Duration _at(double ratio) =>
    Duration(milliseconds: (_episode.inMilliseconds * ratio).round());

NextEpisodeAction _decide({
  bool inTriggerWindow = true,
  bool resumePromptVisible = false,
  bool continueWatchingOn = false,
  bool hasPlayableNextEpisode = true,
  bool hasAnyNextEpisode = true,
  bool overlayVisible = false,
  bool overlayDismissed = false,
  bool autoPlayFired = false,
}) {
  return NextEpisodePlanner.decideAction(
    inTriggerWindow: inTriggerWindow,
    resumePromptVisible: resumePromptVisible,
    continueWatchingOn: continueWatchingOn,
    hasPlayableNextEpisode: hasPlayableNextEpisode,
    hasAnyNextEpisode: hasAnyNextEpisode,
    overlayVisible: overlayVisible,
    overlayDismissed: overlayDismissed,
    autoPlayFired: autoPlayFired,
  );
}

void main() {
  group('isInTriggerWindow', () {
    bool window(Duration position, {int countdown = 10}) =>
        NextEpisodePlanner.isInTriggerWindow(
          position: position,
          duration: _episode,
          countdownSeconds: countdown,
        );

    test('does not fire in the body of the episode', () {
      expect(window(_at(0.5)), isFalse);
      expect(window(_at(0.89)), isFalse);
    });

    test('fires once inside the final tenth', () {
      expect(window(_at(0.90)), isTrue);
      expect(window(_at(0.95)), isTrue);
    });

    test('fires on the countdown fallback for short content', () {
      // 30 s clip: 10% is 3 s in, far too late to be useful. The
      // seconds-remaining rule is what covers it.
      const short = Duration(seconds: 30);
      expect(
        NextEpisodePlanner.isInTriggerWindow(
          position: const Duration(seconds: 21),
          duration: short,
          countdownSeconds: 10,
        ),
        isTrue,
      );
      expect(
        NextEpisodePlanner.isInTriggerWindow(
          position: const Duration(seconds: 5),
          duration: short,
          countdownSeconds: 10,
        ),
        isFalse,
      );
    });

    test('does not fire once the episode has ended', () {
      // Completion is the playback-completion watcher's job — it hands off
      // directly rather than showing a countdown for something already over.
      expect(window(_episode), isFalse);
      expect(window(_episode + const Duration(seconds: 5)), isFalse);
    });

    test('is false for an unknown duration', () {
      expect(
        NextEpisodePlanner.isInTriggerWindow(
          position: const Duration(seconds: 10),
          duration: Duration.zero,
          countdownSeconds: 10,
        ),
        isFalse,
        reason: 'mpv reports zero duration during initial open',
      );
    });
  });

  group('decideAction — default (countdown) flow', () {
    test('shows the overlay inside the window', () {
      expect(_decide(), NextEpisodeAction.showOverlay);
    });

    test('does nothing outside the window', () {
      expect(_decide(inTriggerWindow: false), NextEpisodeAction.none);
    });

    test('a TMDB-only next episode is enough to offer the overlay', () {
      // Not downloaded yet — the overlay offers to fetch it.
      expect(
        _decide(hasPlayableNextEpisode: false, hasAnyNextEpisode: true),
        NextEpisodeAction.showOverlay,
      );
    });

    test('no next episode at all means no overlay', () {
      expect(
        _decide(hasPlayableNextEpisode: false, hasAnyNextEpisode: false),
        NextEpisodeAction.none,
      );
    });

    test('does not re-show once dismissed', () {
      expect(_decide(overlayDismissed: true), NextEpisodeAction.none);
    });

    test('does not re-show while already visible', () {
      expect(_decide(overlayVisible: true), NextEpisodeAction.none);
    });

    test('yields to the resume prompt', () {
      // Two modal decisions at once ("resume from 12:34?" plus a countdown)
      // is one too many.
      expect(_decide(resumePromptVisible: true), NextEpisodeAction.none);
    });
  });

  group('decideAction — Continue Watching flow', () {
    test('auto-plays without a countdown', () {
      expect(_decide(continueWatchingOn: true), NextEpisodeAction.autoPlay);
    });

    test('fires only once', () {
      expect(
        _decide(continueWatchingOn: true, autoPlayFired: true),
        NextEpisodeAction.none,
      );
    });

    test('waits for a playable episode rather than showing the overlay', () {
      // The explicit toggle IS consent to skip the prompt, so falling back
      // to a countdown card while the next episode buffers would be a
      // regression from what the user asked for.
      expect(
        _decide(
          continueWatchingOn: true,
          hasPlayableNextEpisode: false,
          hasAnyNextEpisode: true,
        ),
        NextEpisodeAction.none,
      );
    });

    test('still yields to the resume prompt', () {
      expect(
        _decide(continueWatchingOn: true, resumePromptVisible: true),
        NextEpisodeAction.none,
      );
    });
  });

  group('shouldTriggerAutoDownload', () {
    bool should({
      bool gateOpen = true,
      bool alreadyTriggered = false,
      double ratio = 0.8,
      double threshold = 0.7,
      Duration? duration,
    }) => NextEpisodePlanner.shouldTriggerAutoDownload(
      gateOpen: gateOpen,
      alreadyTriggered: alreadyTriggered,
      position: _at(ratio),
      duration: duration ?? _episode,
      threshold: threshold,
    );

    test('fires once past the threshold', () {
      expect(should(ratio: 0.70), isTrue);
      expect(should(ratio: 0.85), isTrue);
    });

    test('does not fire before the threshold', () {
      expect(should(ratio: 0.69), isFalse);
    });

    test('respects a closed gate', () {
      expect(should(gateOpen: false), isFalse);
    });

    test('does not re-fire once triggered', () {
      expect(should(alreadyTriggered: true), isFalse);
    });

    test('is false for an unknown duration', () {
      expect(should(duration: Duration.zero), isFalse);
    });

    test('fires well before the overlay window so there is time to buffer', () {
      // The whole point of the 0.7 default: start fetching while there are
      // still ~13 minutes of episode left.
      expect(should(ratio: 0.71), isTrue);
      expect(
        NextEpisodePlanner.isInTriggerWindow(
          position: _at(0.71),
          duration: _episode,
          countdownSeconds: 10,
        ),
        isFalse,
      );
    });
  });

  group('planner guards latch', () {
    NextEpisodePlanner planner({bool bingeEnabled = true}) =>
        NextEpisodePlanner(bingeEnabled: bingeEnabled);

    NextEpisodeAction tick(
      NextEpisodePlanner p, {
      bool continueWatchingOn = false,
      double ratio = 0.95,
    }) => p.evaluatePosition(
      position: _at(ratio),
      duration: _episode,
      countdownSeconds: 10,
      resumePromptVisible: false,
      continueWatchingOn: continueWatchingOn,
      hasPlayableNextEpisode: true,
      hasAnyNextEpisode: true,
    );

    test('binge disabled suppresses everything', () {
      final p = planner(bingeEnabled: false);
      expect(tick(p), NextEpisodeAction.none);
      expect(tick(p, continueWatchingOn: true), NextEpisodeAction.none);
    });

    test('overlay shows once, then stays quiet on later ticks', () {
      final p = planner();
      expect(tick(p), NextEpisodeAction.showOverlay);
      expect(p.overlayVisible, isTrue);
      expect(tick(p), NextEpisodeAction.none);
      expect(tick(p), NextEpisodeAction.none);
    });

    test('dismissing latches so the overlay never returns', () {
      final p = planner();
      expect(tick(p), NextEpisodeAction.showOverlay);
      p.dismissOverlay();
      expect(p.overlayVisible, isFalse);
      expect(p.overlayDismissed, isTrue);
      expect(tick(p), NextEpisodeAction.none);
    });

    test('auto-play fires exactly once across many position ticks', () {
      final p = planner();
      expect(tick(p, continueWatchingOn: true), NextEpisodeAction.autoPlay);
      expect(p.autoPlayFired, isTrue);
      for (var i = 0; i < 20; i++) {
        expect(tick(p, continueWatchingOn: true), NextEpisodeAction.none);
      }
    });

    test('auto-download threshold claim is one-shot', () {
      final p = planner();
      bool claim() => p.claimAutoDownloadAtThreshold(
        gateOpen: true,
        position: _at(0.8),
        duration: _episode,
        threshold: 0.7,
      );
      expect(claim(), isTrue);
      expect(p.autoDownloadTriggered, isTrue);
      expect(claim(), isFalse);
    });

    test('claimAutoDownloadNow bypasses the threshold but not the guard', () {
      final p = planner();
      expect(p.claimAutoDownloadNow(), isTrue);
      expect(p.claimAutoDownloadNow(), isFalse);
    });

    test('an in-flight threshold download blocks the immediate claim', () {
      // Flipping Continue Watching on after auto-download already fired must
      // not start a second download of the same episode.
      final p = planner();
      expect(
        p.claimAutoDownloadAtThreshold(
          gateOpen: true,
          position: _at(0.8),
          duration: _episode,
          threshold: 0.7,
        ),
        isTrue,
      );
      expect(p.claimAutoDownloadNow(), isFalse);
    });

    test('an immediate claim blocks the later threshold crossing', () {
      final p = planner();
      expect(p.claimAutoDownloadNow(), isTrue);
      expect(
        p.claimAutoDownloadAtThreshold(
          gateOpen: true,
          position: _at(0.9),
          duration: _episode,
          threshold: 0.7,
        ),
        isFalse,
      );
    });
  });
}
