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
class WindowStateService with WindowListener {
  static const _boundsKey = 'window_bounds';
  static const _maximizedKey = 'window_maximized';

  final SharedPreferences _prefs;
  Timer? _saveDebouncer;

  WindowStateService(this._prefs);

  /// Load the last-saved window state. Returns `(null, false)` when nothing
  /// has been saved yet.
  ({Rect? bounds, bool maximized}) loadState() {
    final boundsJson = _prefs.getString(_boundsKey);
    final maximized = _prefs.getBool(_maximizedKey) ?? false;

    Rect? bounds;
    if (boundsJson != null) {
      try {
        final map = jsonDecode(boundsJson) as Map<String, dynamic>;
        bounds = Rect.fromLTWH(
          (map['x'] as num).toDouble(),
          (map['y'] as num).toDouble(),
          (map['width'] as num).toDouble(),
          (map['height'] as num).toDouble(),
        );
      } catch (_) {
        bounds = null;
      }
    }
    return (bounds: bounds, maximized: maximized);
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

  @override
  void onWindowResized() => _debouncedSave();

  @override
  void onWindowMoved() => _debouncedSave();

  @override
  void onWindowMaximize() => saveNow();

  @override
  void onWindowUnmaximize() => saveNow();

  @override
  void onWindowClose() => saveNow();

  void dispose() {
    _saveDebouncer?.cancel();
  }
}
