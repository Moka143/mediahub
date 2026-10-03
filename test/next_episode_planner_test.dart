import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/services/next_episode_planner.dart';

/// A 45-minute episode — the shape most of these rules were tuned for.
const _episode = Duration(minutes: 45);

Duration _at(double ratio) =>
    Duration(milliseconds: (_episode.inMilliseconds * ratio).round());

NextEpisodeAction _decide({
  bool inTriggerWindow = true,
  bool resumePromptVisible = false,
  bool continueWatchingOn = false,
  bool hasAnyNextEpisode = true,
  bool overlayOffered = false,
}) {
  return NextEpisodePlanner.decideAction(
    inTriggerWindow: inTriggerWindow,
    resumePromptVisible: resumePromptVisible,
    continueWatchingOn: continueWatchingOn,
    hasAnyNextEpisode: hasAnyNextEpisode,
    overlayOffered: overlayOffered,
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
      expect(_decide(hasAnyNextEpisode: true), NextEpisodeAction.showOverlay);
    });

    test('no next episode at all means no overlay', () {
      expect(_decide(hasAnyNextEpisode: false), NextEpisodeAction.none);
    });

    test('does not re-show once already offered', () {
      expect(_decide(overlayOffered: true), NextEpisodeAction.none);
    });

    test('yields to the resume prompt', () {
      // Two modal decisions at once ("resume from 12:34?" plus a countdown)
      // is one too many.
      expect(_decide(resumePromptVisible: true), NextEpisodeAction.none);
    });
  });

  group('decideAction — Continue Watching flow', () {
    test('does not overlay or jump mid-episode', () {
      // Prefetch is a separate watcher. Handoff is on playback completion.
      expect(_decide(continueWatchingOn: true), NextEpisodeAction.none);
    });

    test('does not auto-play before the credits window', () {
      expect(
        _decide(continueWatchingOn: true, inTriggerWindow: false),
        NextEpisodeAction.none,
      );
    });

    test('does not show the overlay while On', () {
      expect(
        _decide(continueWatchingOn: true, hasAnyNextEpisode: true),
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
      expect(p.overlayOffered, isTrue);
      expect(p.overlayActive, isTrue);
      expect(tick(p), NextEpisodeAction.none);
      expect(tick(p), NextEpisodeAction.none);
    });

    test('minimize keeps the offer; restore works past the trigger window', () {
      final p = planner();
      expect(tick(p), NextEpisodeAction.showOverlay);
      p.minimizeOverlay();
      expect(p.overlayMinimized, isTrue);
      expect(p.overlayActive, isTrue);
      expect(tick(p, ratio: 0.5), NextEpisodeAction.none);
      expect(p.overlayOffered, isTrue);
      expect(p.overlayActive, isTrue);
      p.restoreOverlay();
      expect(p.overlayMinimized, isFalse);
      expect(p.overlayActive, isTrue);
      expect(tick(p), NextEpisodeAction.none);
    });

    test('consume hides the prompt for the rest of the episode', () {
      final p = planner();
      expect(tick(p), NextEpisodeAction.showOverlay);
      p.consumeOverlay();
      expect(p.overlayActive, isFalse);
      expect(p.overlayOffered, isTrue);
      expect(tick(p), NextEpisodeAction.none);
      p.restoreOverlay();
      expect(p.overlayActive, isFalse);
    });

    test('On never overlays or auto-plays from the position watcher', () {
      final p = planner();
      for (var i = 0; i < 20; i++) {
        expect(tick(p, continueWatchingOn: true), NextEpisodeAction.none);
      }
      expect(p.overlayOffered, isFalse);
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

    test('claim before the threshold does not latch', () {
      // Turning Continue Watching On at 20% must not start prefetch, and
      // must not burn the one-shot so the 70% crossing can still fire.
      final p = planner();
      expect(
        p.claimAutoDownloadAtThreshold(
          gateOpen: true,
          position: _at(0.2),
          duration: _episode,
          threshold: 0.7,
        ),
        isFalse,
      );
      expect(p.autoDownloadTriggered, isFalse);
      expect(
        p.claimAutoDownloadAtThreshold(
          gateOpen: true,
          position: _at(0.8),
          duration: _episode,
          threshold: 0.7,
        ),
        isTrue,
      );
    });
  });

  group('which episode comes next, and where it is', () {
    LocalMediaFile ep(String show, int s, int e, {String? path}) =>
        LocalMediaFile(
          path: path ?? '/lib/$show.S${s}E$e.mkv',
          fileName: '$show.S${s}E$e.mkv',
          sizeBytes: 1,
          modifiedDate: DateTime(2026),
          extension: 'mkv',
          showName: show,
          seasonNumber: s,
          episodeNumber: e,
        );

    test("TMDB's answer is the only candidate when there is one", () {
      expect(
        NextEpisodePlanner.nextEpisodeCandidates(
          fromTmdb: (season: 2, episode: 1),
          season: 1,
          episode: 10,
        ),
        [(season: 2, episode: 1)],
      );
    });

    test('without TMDB: next in the season, then the next season', () {
      expect(NextEpisodePlanner.nextEpisodeCandidates(season: 1, episode: 4), [
        (season: 1, episode: 5),
        (season: 2, episode: 1),
      ]);
      expect(NextEpisodePlanner.nextEpisodeCandidates(), isEmpty);
    });

    test('files come back in candidate order, same show only', () {
      final library = [
        ep('Young Sheldon', 1, 5),
        ep('You', 2, 1),
        ep('You', 1, 5),
        ep('You', 1, 4, path: '/playing.mkv'),
      ];
      final files = NextEpisodePlanner.nextEpisodeFilesIn(
        library,
        showName: 'You',
        playingPath: '/playing.mkv',
        candidates: [(season: 1, episode: 5), (season: 2, episode: 1)],
      );
      expect(files.map((f) => f.fileName), ['You.S1E5.mkv', 'You.S2E1.mkv']);
    });

    test('the file playing now is never its own next episode', () {
      final playing = ep('Dark', 1, 2, path: '/now.mkv');
      expect(
        NextEpisodePlanner.nextEpisodeFilesIn(
          [playing],
          showName: 'Dark',
          playingPath: '/now.mkv',
          candidates: [(season: 1, episode: 2)],
        ),
        isEmpty,
      );
    });
  });
}
