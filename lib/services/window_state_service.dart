import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

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

  // Reject rectangles that would place the window invisibly: zero/negative
  // dimensions, NaN/infinite coordinates, or values too small to host a usable
  // window. (A post-BSOD prefs file recovered as all-zero bytes deserializes
  // to Rect(0,0,0,0), which previously got applied verbatim.)
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
    try {
      await saveNow().timeout(closeSaveTimeout);
    } catch (_) {
      // Disk full, prefs locked, a window_manager call that never answered —
      // none of it is a reason to trap the user in the app.
    } finally {
      await onClosed();
    }
  }

  void dispose() {
    _saveDebouncer?.cancel();
  }
}
