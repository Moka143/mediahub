# Decomposing `video_player_screen.dart`

**Status:** done. Steps 1–4 landed as one commit each. Step 5's tests did
*not* land with them, whatever an earlier version of this line said — no test
imported anything under `lib/screens/` until the October 2026 audit fixes,
which added them (see *Step 5, as it landed* at the end).
**Result:** 1,727 → 611 lines, across four mixins and two widgets. Suite 491 →
553. `flutter analyze` clean throughout.

| Step | Lines after | What came out |
|---|---|---|
| 1 | 947 | `_player_next_episode_controller.dart` |
| 2 | 781 | `_player_streaming_health.dart` |
| 3 | 697 | `_player_window_chrome.dart` |
| 4 | 611 | `widgets/player/player_overlay_stack.dart`, `up_next_chip.dart` |

Three things differed from the plan below, all recorded in the commits:

  * **`releaseSessionOwnership()` was not needed.** The plan assumed the
    handoff cleared the screen's own `_ownedSessionId`; it actually clears
    `_prefetchSessionId`, which the mixin owns outright. The seam that *was*
    needed is `openReplacementPlayer` — navigation stays on the screen so the
    two files do not import each other.
  * **`isFullscreen` / `toggleFullscreen` had to be renamed.**
    `media_kit_video` exports top-level functions by both names, and the
    unqualified identifiers resolved to those rather than the new mixin
    members. They are now `isWindowFullscreen` / `toggleWindowFullscreen`.
  * **Step 4 split by test kind rather than by widget.** The `??` chains that
    decide what the Up Next chip says came out as `UpNextChip`, a pure value
    with unit tests; only the layering and gating went into the widget, where
    widget tests fit.

---

## Original plan

**Target:** 1,727 lines / 28 state fields → ~450 lines / 9 state fields, in five
reviewable steps, with no behaviour change.

---

## Why this file is the one worth splitting

One `State` class currently owns eleven independent concerns at once:

| Concern | Members | Lines |
|---|---|---|
| **Next episode / binge** | `_setupNextEpisodeWatcher`, `_checkTmdbForNextEpisode`, `_onContinueWatchingActivated`, `_setupAutoDownloadWatcher`, `_triggerAutoDownload`, `_setupPlaybackCompletionWatcher`, `_playNextEpisodeFromDisk`, `_onPlayNextEpisode`, `_setNextEpisodePrefetch`, `_prefetchNextEpisode`, `_monitorNextEpisodeStream` | **740** |
| `build()` | one method, one `Stack` | 185 |
| **Open / resume / exit** | `_initializePlayer`, `_autoLoadSubtitle`, `_handleResume`, `_exitPlayer` | 184 |
| **Streaming health** | `_startPlaybackHealthMonitor`, `_setupStreamingBufferingDebounce`, `_showStreamingStatus` | 106 |
| **Gestures / chrome** | drag-seek, skip ripple, hide-controls timer, `_handleKeyEvent` | ~100 |
| **Fullscreen** | `_toggleFullscreen` | 52 |
| `dispose()` | 9 cancels, 2 session releases, fullscreen unwind | 41 |

The cost is not the line count, it's the **lifetimes**. Four `Timer?`s, five
`StreamSubscription`s, a `PlaybackHealthMonitor`, a `FocusNode` and two
streaming-session ids are each cancelled by hand in one 41-line `dispose()`.
`analysis_options.yaml` says this app's regression history is dominated by
async-lifecycle mistakes; this is the file with the most of them in one scope.

Next-episode alone is 43% of the file, and it is the piece with no reason to
share a scope with anything else: it has its own subscriptions, its own
one-shot guards, its own streaming session, and its own proxy URL.

---

## The pattern: `mixin … on ConsumerState<T>`

Already proven in this repo by
[`_details_playback_controller.dart`](../lib/screens/_details_playback_controller.dart),
which pulled ~200 duplicated lines out of the movie and show details screens.

This is the right shape here, and the alternatives are not:

* **Not a plain controller object.** `NextEpisodePlanner`'s own docstring
  already rejected that, and the reason still holds: the flow needs `Ref`,
  `BuildContext`, `mounted` and `setState`, so a standalone class means "a
  constructor full of callbacks that just relay back to the widget".
* **Not a Riverpod `Notifier`.** Its lifetime is the provider's, not the
  route's, and this state must die exactly when the route does.
* **A mixin keeps all four for free.** `ref`, `context`, `mounted` and
  `setState` stay in scope, so **every moved line moves verbatim** — which is
  what makes "preserve the logic" checkable by `git diff` rather than by
  reading.

`build()` reads `_nextEpisode` (11×), `_nextEpisodeFromTmdb` (3×), `_planner`
(2×) and the streaming-status fields directly. Under a mixin those stay direct
field reads; under any other option they become plumbing.

### Two house rules for every step

1. **Explicit teardown, not `super.dispose()` chaining.** Each mixin exposes
   one `disposeX()`, and the screen's `dispose()` calls them in the order the
   current body already uses. Mixin `super` ordering is linearisation order,
   which is not obvious at the call site — and the current order is
   load-bearing (the health monitor must stop before its sessions are
   cancelled).
2. **Move, don't improve.** No renames, no signature changes, no "while I'm
   here" fixes in the same commit. Anything worth changing gets its own commit
   after the move, where the diff shows only the change.

---

## Step 1 — `PlayerNextEpisodeController` (740 lines)

**New file:** `lib/screens/_player_next_episode_controller.dart`
**Result:** 1,727 → ~990 lines.

Moves the eleven methods above, plus the fields only they touch:

```
_nextEpisode                        _nextEpisodeStreamingTorrentHash
_nextEpisodeFromTmdb                _nextEpisodeStreamingFileIndex
_currentShowId                      _nextEpisodeStreamingProxyUrl
_currentImdbId                      _nextPrefetch
_nextEpisodeDownloadStarted         _nextPrefetchHideTimer
_downloadingEpisode                 _prefetchSessionId
_positionSubscription   _completedSubscription
_autoDownloadSubscription   _nextEpisodeSubscription
```

The mixin declares what it still needs from the host:

```dart
mixin PlayerNextEpisodeController<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// The episode currently playing.
  LocalMediaFile get playingFile;

  /// Binge decisions + one-shot guards. Owned by the screen because
  /// `build()` reads it too.
  NextEpisodePlanner get planner;

  /// Suppresses the countdown while the resume dialog is up.
  bool get resumePromptVisible;

  /// Hand this screen's session to the replacement player. Clears
  /// `_ownedSessionId` so `dispose()` does not cancel the proxy the next
  /// episode is about to read from.
  void releaseSessionOwnership();

  void disposeNextEpisodeController();
}
```

`releaseSessionOwnership()` is the one genuinely subtle seam — the ownership
comment on `VideoPlayerScreen.streamingSessionId` explains why. Naming it makes
the handoff explicit instead of an assignment buried in `_onPlayNextEpisode`.

**Verify:** `flutter analyze` clean; full suite green; then by hand — play an
episode to the credits with binge on, take the countdown, and confirm the next
episode opens *through the proxy* (the seek bar's buffered track must move; a
dead track means the proxy URL was dropped in the move).

## Step 2 — `PlayerStreamingHealth` (106 lines)

**New file:** `lib/screens/_player_streaming_health.dart`
**Result:** ~990 → ~880 lines.

Moves `_startPlaybackHealthMonitor`, `_setupStreamingBufferingDebounce`,
`_showStreamingStatus` and their eight fields (`_healthMonitor`,
`_streamBuffering`, `_streamBufferingGrace`, `_bufferingDebounceTimer`,
`_bufferingSubscription`, `_streamingDownloadedRatio`, `_bufferedSpans`, and
the four `_streaming*` status fields).

Easiest step: `PlaybackHealthMonitor` is already self-contained with its own
timers, and it already has a test. The mixin is just the wiring plus the
debounce.

**Verify:** `playback_health_monitor_test.dart` still passes untouched. By
hand — start a stream and outrun the download edge; the indicator must still
debounce rather than strobe.

## Step 3 — `PlayerWindowChrome` (52 lines)

**New file:** `lib/screens/_player_window_chrome.dart`
**Result:** ~880 → ~820 lines.

`_toggleFullscreen`, `_isFullscreen`, `_preFullscreenSize`, and the fullscreen
unwind currently sitting at the bottom of `dispose()`.

Worth its own step because it is the most platform-specific code in the file
(macOS will not restore window bounds on leaving fullscreen, so we replay them)
and it is the piece most recently touched — commit `61dc989`.

**Verify:** by hand on macOS *and* Windows — enter fullscreen, exit, and
confirm the window returns to its previous size; then close the player while
still in fullscreen.

## Step 4 — extract the overlay stack from `build()` (185 lines)

**New file:** `lib/widgets/player/player_overlay_stack.dart`
**Result:** ~820 → ~600 lines.

`build()` is one `Stack` with ~10 conditional children. Each becomes a small
widget taking exactly what it renders. This is the step that adds **widget
tests** — currently the whole file has none, and the overlays are pure
functions of state once they no longer read `_VideoPlayerScreenState` fields
directly.

Do this step last of the four, because steps 1–3 are what make the state each
overlay needs nameable.

## Step 5 — tests on the seams

With the mixins in place, three things become testable that are not today:

* `releaseSessionOwnership()` — that a handoff clears the id, so `dispose()`
  cannot cancel a session the next screen is reading from. This is the leak the
  `streamingSessionId` docstring describes, and nothing currently guards it.
* The next-episode resolution ladder — TMDB first, local scan second, and the
  `nextLocalEpisodeProvider` fallback when TMDB is unreachable.
* Overlay visibility, as widget tests over step 4's extracted widgets.

---

## Order, and what not to do

Do steps **1 → 2 → 3 → 4**, one commit each, `flutter analyze` + `flutter test`
between every one. Step 1 first because it is 43% of the file and unblocks the
rest; step 4 last because it depends on 1–3 having named the state.

Do **not**:

* fold two steps into one commit — the value of a verbatim move is that the
  diff is reviewable, and two moves at once is not;
* change `dispose()` ordering while moving (see house rule 1);
* pull `NextEpisodePlanner`'s decisions into the new mixin. The split between
  *decisions* (planner, tested) and *side effects* (screen, untested) is
  deliberate and documented; step 1 moves the side effects to a new home, it
  does not move the boundary.

---

## Step 5, as it landed (October 2026)

`releaseSessionOwnership()` was never needed (see above), so the three seams
became:

* **Session hand-off and lifetime** — `test/video_player_screen_test.dart`
  (leaving while a file is still opening stops it; a route removed from under
  the player stops it; a failed stream goes back for another source) and
  `test/details_playback_controller_test.dart` (Hide and Cancel during and
  after the add, no second overlay, the shared download helper).
* **The next-episode lookup order** — the ladder now lives in
  `NextEpisodePlanner.nextEpisodeCandidates` / `nextEpisodeFilesIn` (TMDB's
  answer first; otherwise next in the season, then the next season; same show
  only, never the playing file), covered in
  `test/next_episode_planner_test.dart`. The mixin keeps only the I/O: the
  TMDB call, which also no longer offers an episode that hasn't aired, and the
  "is it finished on disk" check.
* **Overlay visibility** — `test/player_overlay_stack_test.dart`,
  `test/next_episode_overlay_test.dart`, `test/player_error_overlay_test.dart`
  and `test/player_keyboard_test.dart`.

