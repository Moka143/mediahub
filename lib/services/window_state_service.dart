import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';

/// Persists window bounds (position + size) and maximized state across
/// launches via SharedPreferences.
///
/// Usage:
///   1. `loadState()` early in `main()` to read the last-saved bounds.
///   2. Apply those bounds to `WindowOptions` / `setBounds` / `maximize` before
///      showing the window.
///   3. Register the instance as a `WindowListener` so resize/move/maximize
///      events persist the new state (debounced).
///   4. `windowManager.setPreventClose(true)`, so the close-time save has
///      somewhere to run — see [onWindowClose].
class WindowStateService with WindowListener {
  static const _boundsKey = 'window_bounds';
  static const _maximizedKey = 'window_maximized';

  /// Upper bound on how long the close-time save may take before the window
  /// is destroyed anyway.
  static const Duration closeSaveTimeout = Duration(seconds: 2);

  final SharedPreferences _prefs;
  Timer? _saveDebouncer;

  /// The close-time save, once one has been started.
  ///
  /// [_saveThenClose] stops *waiting* on this after [closeSaveTimeout], but the
  /// write itself carries on — and the teardown that follows now ends in
  /// `exit()` on Windows, which would cut it off mid-file. Exposed so the
  /// shutdown path can give it one last moment to land. Never completes with an
  /// error: the failure is logged where it happens.
  Future<void>? _inFlightSave;

  /// The close-time save, or an already-completed future when none ran.
  Future<void> get pendingSave => _inFlightSave ?? Future<void>.value();

  /// How to finish closing once the state is written. Injected so a test can
  /// observe it, and so this file need not decide the app's exit semantics.
  final Future<void> Function() onClosed;

  WindowStateService(this._prefs, {Future<void> Function()? onClosed})
    : onClosed = onClosed ?? windowManager.destroy;

  /// Load the last-saved window state. Returns `(null, false)` when nothing
  /// has been saved yet.
  ({Rect? bounds, bool maximized}) loadState() {
    final boundsJson = _prefs.getString(_boundsKey);
    final maximized = _prefs.getBool(_maximizedKey) ?? false;

    Rect? bounds;
    if (boundsJson != null) {
      try {
        final map = jsonDecode(boundsJson) as Map<String, dynamic>;
        final candidate = Rect.fromLTWH(
          (map['x'] as num).toDouble(),
          (map['y'] as num).toDouble(),
          (map['width'] as num).toDouble(),
          (map['height'] as num).toDouble(),
        );
        if (isSane(candidate)) bounds = candidate;
      } catch (_) {
        bounds = null;
      }
    }
    return (bounds: bounds, maximized: maximized);
  }

  // Reject rectangles that are malformed in themselves: zero/negative
  // dimensions, NaN/infinite coordinates, or values too small to host a usable
  // window. (A post-BSOD prefs file recovered as all-zero bytes deserializes
  // to Rect(0,0,0,0), which previously got applied verbatim.)
  //
  // Says nothing about *where* the rectangle is — a perfectly well-formed
  // rectangle can still sit on a monitor that is no longer plugged in. That
  // is [isOnScreen]'s job, because it needs to know about displays and this
  // does not.
  @visibleForTesting
  static bool isSane(Rect r) {
    if (!r.left.isFinite ||
        !r.top.isFinite ||
        !r.width.isFinite ||
        !r.height.isFinite) {
      return false;
    }
    if (r.width < 200 || r.height < 200) return false;
    return true;
  }

  /// How much of the window must overlap a display for it to count as
  /// reachable — enough to see it and to get hold of its title bar.
  static const double minVisibleExtent = 120;

  /// Whether [window] overlaps any of [workAreas] enough to be usable.
  ///
  /// The case this exists for: the window was last closed on a second
  /// monitor, that monitor is now gone, and the saved position points into
  /// space that no longer exists. Windows will happily place a window at
  /// x=3000 on a 1280-wide desktop — `IsWindowVisible` even reports true —
  /// and the user has no way to see it or drag it back. Undocking a laptop
  /// is all it takes.
  ///
  /// [workAreas] are the usable parts of each display, excluding the taskbar
  /// or dock, so a window that only overlaps the taskbar strip is correctly
  /// treated as out of reach.
  @visibleForTesting
  static bool isOnScreen(Rect window, List<Rect> workAreas) {
    for (final area in workAreas) {
      final overlap = window.intersect(area);
      // A disjoint intersect() comes back with negative extents, which fails
      // this comparison without needing a separate emptiness check.
      if (overlap.width >= minVisibleExtent &&
          overlap.height >= minVisibleExtent) {
        return true;
      }
    }
    return false;
  }

  /// Shrink [desired] to fit inside [workArea], but never below [minimum].
  ///
  /// The default 1100x720 is taller than the work area of a 720p screen, and
  /// centring a window taller than the screen puts its title bar above the
  /// top edge where it cannot be dragged. [minimum] wins over the work area
  /// when the two conflict: a window clipped at the bottom is still usable,
  /// one narrower than its own layout is not.
  static Size fitToWorkArea(Size desired, Size workArea, Size minimum) {
    return Size(
      math.max(minimum.width, math.min(desired.width, workArea.width)),
      math.max(minimum.height, math.min(desired.height, workArea.height)),
    );
  }

  /// [loadState], with saved bounds discarded when they no longer land on a
  /// connected display.
  ///
  /// An empty [workAreas] means the platform could not be asked. That is not
  /// evidence the bounds are bad, so they are kept — losing someone's window
  /// layout because a display query failed would be its own bug.
  ({Rect? bounds, bool maximized}) loadStateFor(List<Rect> workAreas) {
    final state = loadState();
    if (state.bounds == null || workAreas.isEmpty) return state;
    if (isOnScreen(state.bounds!, workAreas)) return state;

    AppLog.w(
      '[WindowState] saved bounds ${state.bounds} are off every connected '
      'display — opening centred instead',
    );
    return (bounds: null, maximized: state.maximized);
  }

  /// Persist the current window state immediately. Maximized wins — we don't
  /// overwrite the last "restored" bounds while the window is maximized, so
  /// unmaximizing on next launch returns to the user's preferred size.
  Future<void> saveNow() async {
    if (await windowManager.isFullScreen()) return;

    final maximized = await windowManager.isMaximized();
    await _prefs.setBool(_maximizedKey, maximized);

    if (!maximized) {
      final bounds = await windowManager.getBounds();
      await _prefs.setString(
        _boundsKey,
        jsonEncode({
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        }),
      );
    }
  }

  void _debouncedSave() {
    _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(milliseconds: 500), saveNow);
  }

  // ── Why so many hooks ──────────────────────────────────────────────────
  //
  // Windows was not remembering the window size, and the reason is which
  // native messages window_manager translates into which events.
  //
  // `resized` / `moved` are emitted from `WM_EXITSIZEMOVE`, and only when a
  // preceding `WM_SIZING` / `WM_MOVING` set the "is resizing" flag. Those
  // arrive during an *interactive border drag* and nothing else. Snap the
  // window with Win+Arrow, drag it to a screen edge, or let a Snap Layout
  // place it, and Windows sends `WM_SIZE` / `WM_WINDOWPOSCHANGED` instead —
  // no event, no save. Snapping is how a great many people size a window, so
  // the size that got remembered was whichever one had last been dragged by
  // hand, if any.
  //
  // So we listen to the continuous variants as well, and to blur, which
  // catches anything the others miss the moment focus leaves the window.
  // Every path is debounced, so a drag that fires `resize` on every mouse
  // move still costs exactly one write.

  @override
  void onWindowResize() => _debouncedSave();

  @override
  void onWindowResized() => _debouncedSave();

  @override
  void onWindowMove() => _debouncedSave();

  @override
  void onWindowMoved() => _debouncedSave();

  /// Alt-tabbing away, clicking another window — and, usefully, most routes
  /// to closing the app. The cheapest catch-all for a size change that
  /// produced no resize event of its own.
  @override
  void onWindowBlur() => _debouncedSave();

  @override
  void onWindowMaximize() => saveNow();

  @override
  void onWindowUnmaximize() => saveNow();

  /// Save synchronously-ish, then let the window go.
  ///
  /// This only works because `main` sets `setPreventClose(true)`. Without it
  /// the native side emits `close` and destroys the window in the same
  /// message, so this method's first `await` never resumes and nothing is
  /// ever written — which is why a change made just before quitting was lost
  /// even when it had fired a resize event.
  ///
  /// [onClosed] performs the actual teardown. It runs whatever happens: a
  /// failed or slow save must never leave a window the user cannot close.
  @override
  void onWindowClose() {
    unawaited(_saveThenClose());
  }

  Future<void> _saveThenClose() async {
    _saveDebouncer?.cancel();

    // Acknowledge the click before doing anything that can take time.
    //
    // Everything after this line — the save, killing the sidecar, tearing down
    // providers, and on Windows the whole of native engine teardown — happens
    // with the window still on screen and no longer repainting, because
    // closing is what stopped the frames. `windowManager.destroy()` on Windows
    // is only `PostQuitMessage(0)`; the HWND is not touched until after every
    // destructor has run. That is the entire "it freezes for fifteen seconds
    // when I close it" report. One `ShowWindow(SW_HIDE)` moves all of it out
    // of sight, and it does not disturb the save: bounds come from
    // `GetWindowRect` and maximized from `IsZoomed`, neither of which cares
    // whether the window is visible.
    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 250));
    } catch (_) {
      // A hide that will not answer is not a reason to stop closing.
    }

    // Held in a field so [pendingSave] can hand it to the shutdown if the
    // timeout below gives up on it. `catchError` first, so the future we stop
    // listening to cannot resurface as an unhandled async error.
    final save = saveNow().catchError((Object e) {
      AppLog.w('[WindowState] close-time save failed: $e');
    });
    _inFlightSave = save;

    try {
      await save.timeout(closeSaveTimeout);
    } on TimeoutException {
      // Disk busy, prefs locked, a window_manager call that never answered —
      // none of it is a reason to trap the user in the app. The write is still
      // running; the shutdown gives it a little longer before exiting.
      AppLog.w(
        '[WindowState] close-time save overran '
        '${closeSaveTimeout.inSeconds}s — carrying on',
      );
    } finally {
      await onClosed();
    }
  }

  void dispose() {
    _saveDebouncer?.cancel();
  }
}
