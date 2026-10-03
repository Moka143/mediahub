import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';

/// Fullscreen for the video player, and the platform quirks it has to work
/// around.
///
/// Step 3 of docs/player-screen-decomposition.md. Small, but the most
/// platform-specific code in the player, so it earns its own file rather
/// than sitting between the gesture handlers and `build()`.
///
/// Three things here are not obvious, and all three are load-bearing:
///
///  * **macOS does not restore window bounds** on leaving fullscreen, so the
///    size is captured on the way in and replayed on the way out.
///  * **Windows keeps WS_CAPTION** through `setFullScreen`, so the title bar
///    stays visible unless it is hidden explicitly and restored after.
///  * **The video surface can be recreated** during the transition, and mpv
///    drops the active subtitle track when it is. The selection is snapshotted
///    before and re-applied 200 ms after.
///
/// [exitWindowFullscreen] is the same unwind, for the case where the player
/// is closed while still fullscreen and there will be no exit transition to
/// do it.
mixin PlayerWindowChrome<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool isWindowFullscreen = false;

  /// Window size captured the first time we go into fullscreen — used
  /// to restore the user's prior window size on exit. macOS in
  /// particular will not preserve the previous bounds when leaving
  /// `setFullScreen(false)`, so we replay it ourselves.
  Size? _preFullscreenSize;

  /// A transition is in flight. A second F press during one used to start
  /// another, interleaving their window calls.
  bool _fullscreenTransition = false;

  /// How long the video surface gets to settle after a transition before
  /// the subtitle selection is re-applied.
  static const Duration _surfaceSettleDelay = Duration(milliseconds: 200);

  Future<void> toggleWindowFullscreen() async {
    if (_fullscreenTransition) return;
    _fullscreenTransition = true;
    try {
      await _toggleWindowFullscreen();
    } finally {
      _fullscreenTransition = false;
    }
  }

  Future<void> _toggleWindowFullscreen() async {
    // Snapshot selected subtitles before the window resizes — on some
    // platforms the video surface is recreated during fullscreen transitions
    // and mpv drops the active external/embedded track. We re-apply below.
    final externalSub = ref.read(currentExternalSubtitleProvider);
    final embeddedSub = ref.read(playerProvider).state.track.subtitle;
    final playerService = ref.read(playerServiceProvider);

    final newFullscreen = !isWindowFullscreen;
    // Capture the user's window size before going fullscreen so we
    // can restore it on exit (macOS otherwise resizes to default).
    if (newFullscreen) {
      try {
        _preFullscreenSize = await windowManager.getSize();
      } catch (_) {
        _preFullscreenSize = null;
      }
      if (!mounted) return;
    }
    setState(() => isWindowFullscreen = newFullscreen);

    // On Windows, setFullScreen leaves WS_CAPTION on the window so the title
    // bar (with min/max/close) still shows. Hide it explicitly before going
    // fullscreen and restore it on exit.
    if (newFullscreen) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
    }
    await windowManager.setFullScreen(newFullscreen);
    if (!newFullscreen) {
      await windowManager.setTitleBarStyle(
        TitleBarStyle.normal,
        windowButtonVisibility: true,
      );
      // Restore pre-fullscreen size so the user's window doesn't snap
      // to the platform's default size.
      final pre = _preFullscreenSize;
      if (pre != null) await windowManager.setSize(pre);
    }

    // Let the surface settle, then restore whichever subtitle was selected.
    await Future<void>.delayed(_surfaceSettleDelay);
    if (!mounted) return;
    if (externalSub != null) {
      await playerService.loadExternalSubtitle(externalSub.url);
    } else if (isRealTrackId(embeddedSub.id)) {
      await playerService.setSubtitleTrack(embeddedSub);
    }
  }

  /// Undo fullscreen without the subtitle round-trip — for leaving the
  /// screen entirely, where there is no surface left to restore a track on.
  ///
  /// Guarded on [isWindowFullscreen] because calling `setFullScreen` when we
  /// are not fullscreen triggers the framework's own resize path and resets
  /// the user's window to the platform default. The flag is cleared before
  /// the first await: the close button awaits this and then `dispose()`
  /// calls it again, and both used to run the full unwind.
  ///
  /// Either way the steps run in order, which matters — `setSize` before
  /// `setFullScreen` has settled restores the wrong bounds.
  Future<void> exitWindowFullscreen() async {
    if (!isWindowFullscreen) return;
    isWindowFullscreen = false;
    await windowManager.setFullScreen(false);
    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    // Restore the size that was active before fullscreen, if known.
    final pre = _preFullscreenSize;
    if (pre != null) {
      await windowManager.setSize(pre);
    }
  }
}
