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
///   1. [loadStateFor] early in `main()`, with the displays' work areas, to
///      read the last-saved bounds that still land on a connected screen.
///   2. Apply those bounds to `WindowOptions` / `setBounds` / `maximize` before
///      showing the window.
///   3. Register the instance as a `WindowListener` so resize/move/maximize
///      events persist the new state (debounced).
///   4. `windowManager.setPreventClose(true)`, so a close reaches
///      [onWindowClose] — which hands it to the app's shutdown, which calls
///      [saveForClose] as one of its steps.
class WindowStateService with WindowListener {
  static const _boundsKey = 'window_bounds';
  static const _maximizedKey = 'window_maximized';

  final SharedPreferences _prefs;
  Timer? _saveDebouncer;

  /// Set once the close-time save has started. After that no event — the
  /// blur and resize that hiding the window fires — may schedule another:
  /// it would land after the shutdown and save the hidden window's state.
  bool _closing = false;

  /// The close-time save, once one has been started.
  ///
  /// The shutdown stops *waiting* on [saveForClose] after its budget, but the
  /// write itself carries on — and on Windows the teardown ends in `exit()`,
  /// which would cut it off mid-file. Exposed so the shutdown can give it one
  /// last moment to land. Never completes with an error: the failure is
  /// logged where it happens.
  Future<void>? _inFlightSave;

  /// The close-time save, or an already-completed future when none ran.
  Future<void> get pendingSave => _inFlightSave ?? Future<void>.value();

  /// What a close of the window starts: the app's shutdown, which saves the
  /// window state as one of its steps and then ends the app.
  final Future<void> Function() onCloseRequested;

  WindowStateService(this._prefs, {required this.onCloseRequested});

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

  /// Shrink [desired] to fit inside [workArea], preferring [minimum] but never
  /// exceeding the work area itself.
  ///
  /// The default 1100x720 is taller than the work area of a 720p screen, and
  /// centring a window taller than the screen puts its title bar above the
  /// top edge where it cannot be dragged.
  ///
  /// The work area wins when the two conflict. It has to: on Windows the work
  /// area arrives in logical pixels, so a 1080p panel at 225% reports about
  /// 853x432 and at 300% about 640x312 — both below the 800x600 design floor.
  /// This used to prefer [minimum], on the reasoning that a bottom-clipped
  /// window beats a too-narrow layout. That stopped being true once `UiScale`
  /// began scaling the layout to fit instead of letting it clip, and it was
  /// the reason the window could not be made to fit a high-DPI monitor.
  static Size fitToWorkArea(Size desired, Size workArea, Size minimum) {
    return Size(
      math.min(workArea.width, math.max(minimum.width, desired.width)),
      math.min(workArea.height, math.max(minimum.height, desired.height)),
    );
  }

  /// Shrink restored [bounds] so they fit the work area they land on.
  ///
  /// Saved bounds are logical pixels measured on whichever display the window
  /// was last closed on. Reopen on a display with fewer logical pixels —
  /// undocking from a 1080p monitor at 100% onto a high-DPI laptop panel, or
  /// the same monitor after the user raised its scale — and the window is
  /// applied verbatim at a size the new screen cannot hold. [isSane] only
  /// floors at 200 and [isOnScreen] only wants 120px of overlap, so nothing
  /// caught this.
  ///
  /// The position is pulled back too, not just the size: a window shrunk in
  /// place can still have its title bar above the top edge.
  ///
  /// Picks the work area with the largest overlap, which is what Windows
  /// itself considers the window's monitor.
  static Rect clampToWorkArea(Rect bounds, List<Rect> workAreas) {
    if (workAreas.isEmpty) return bounds;

    var best = workAreas.first;
    var bestArea = 0.0;
    for (final area in workAreas) {
      final overlap = bounds.intersect(area);
      final covered =
          math.max(0.0, overlap.width) * math.max(0.0, overlap.height);
      if (covered > bestArea) {
        bestArea = covered;
        best = area;
      }
    }

    final width = math.min(bounds.width, best.width);
    final height = math.min(bounds.height, best.height);
    final left = math.min(
      math.max(bounds.left, best.left),
      math.max(best.left, best.right - width),
    );
    final top = math.min(
      math.max(bounds.top, best.top),
      math.max(best.top, best.bottom - height),
    );
    return Rect.fromLTWH(left, top, width, height);
  }

  /// A display's work area, as screen_retriever reports it, expressed in the
  /// units window_manager uses for the window's bounds — so the two can be
  /// compared at all.
  ///
  /// On Windows they are not the same units on a desktop that mixes display
  /// scales: screen_retriever divides each display's rectangle by *that
  /// display's* scale, while window_manager divides the window's by the scale
  /// of the display the window is on. Multiplying the area back out to
  /// physical pixels and dividing by the window's scale puts both in the
  /// window's space — the frame `WindowFitService` already compares in.
  ///
  /// macOS has one global coordinate space of points across every display,
  /// so there `main` passes 1 for both scales and the area is unchanged.
  static Rect toWindowSpace(
    Rect area, {
    required double displayScale,
    required double windowScale,
  }) {
    if (displayScale <= 0 || windowScale <= 0) return area;
    final factor = displayScale / windowScale;
    return Rect.fromLTWH(
      area.left * factor,
      area.top * factor,
      area.width * factor,
      area.height * factor,
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
    if (_closing) return;
    await _save();
  }

  Future<void> _save() async {
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
    if (_closing) return;
    _saveDebouncer?.cancel();
    _saveDebouncer = Timer(const Duration(milliseconds: 500), _saveQuietly);
  }

  /// [saveNow] for the event handlers, which have nobody to report a failure
  /// to: a window position that did not save is a log line, not a crash.
  void _saveQuietly() {
    unawaited(
      saveNow().catchError((Object e) {
        AppLog.w('[WindowState] could not save the window state: $e');
      }),
    );
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
  void onWindowMaximize() => _saveQuietly();

  @override
  void onWindowUnmaximize() => _saveQuietly();

  /// The window was asked to close: by its close button, ⌘W, Alt+F4 or the
  /// taskbar.
  ///
  /// This only reaches us because `main` sets `setPreventClose(true)`; the
  /// close itself — saving included — is the shutdown's job from here, so
  /// that every way of leaving the app runs the same teardown once.
  @override
  void onWindowClose() {
    unawaited(onCloseRequested());
  }

  /// The close-time save. Called once, by the shutdown, after the window has
  /// been hidden: bounds come from `GetWindowRect` / the window's frame and
  /// maximized from `IsZoomed` / `isZoomed`, none of which care whether the
  /// window is visible.
  ///
  /// Never throws. The shutdown bounds how long it waits, and hands
  /// [pendingSave] a last moment before the process ends.
  Future<void> saveForClose() {
    _closing = true;
    _saveDebouncer?.cancel();
    return _inFlightSave ??= _save().catchError((Object e) {
      AppLog.w('[WindowState] close-time save failed: $e');
    });
  }
}
