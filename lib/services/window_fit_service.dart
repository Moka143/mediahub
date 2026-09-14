import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app_logger.dart';

/// Keeps the window inside the work area of whichever display it is on, as
/// that changes underneath it.
///
/// The case this exists for: the user drags the window from a 100% internal
/// panel onto a 250% external monitor. Windows fires `WM_DPICHANGED` and
/// Flutter re-dispatches metrics, so the layout reflows on its own — `UiScale`
/// picks up the smaller logical viewport without being told. What nobody
/// checked is whether the window still *fits*: the new display can have far
/// fewer logical pixels than the one the size was chosen on, and the window
/// is left hanging off the bottom of the screen.
///
/// Only ever shrinks. Growing the window, or moving it, would be fighting the
/// user; a window clipped off the edge of its own screen is the only failure
/// worth correcting without being asked.
class WindowFitService with WidgetsBindingObserver {
  Timer? _debounce;
  bool _busy = false;

  void start() => WidgetsBinding.instance.addObserver(this);

  void stop() {
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeMetrics() {
    // A drag across a monitor boundary emits a burst of these. Collapse them.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _refit);
  }

  Future<void> _refit() async {
    if (_busy) return;
    _busy = true;
    try {
      if (await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }

      // Everything below is in PHYSICAL pixels. screen_retriever divides each
      // display's work area by *that display's* scale factor, while
      // window_manager divides bounds by the app view's devicePixelRatio — on
      // a mixed-DPI desktop those are two different logical spaces and cannot
      // be compared. Multiplying both back out is the only honest frame.
      final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
      final bounds = await windowManager.getBounds();
      final window = Rect.fromLTWH(
        bounds.left * dpr,
        bounds.top * dpr,
        bounds.width * dpr,
        bounds.height * dpr,
      );

      Rect? host;
      var hostArea = 0.0;
      for (final display in await screenRetriever.getAllDisplays()) {
        final scale = (display.scaleFactor ?? 1).toDouble();
        final position = display.visiblePosition ?? Offset.zero;
        final size = display.visibleSize ?? display.size;
        final area = Rect.fromLTWH(
          position.dx * scale,
          position.dy * scale,
          size.width * scale,
          size.height * scale,
        );
        final overlap = window.intersect(area);
        final covered =
            math.max(0.0, overlap.width) * math.max(0.0, overlap.height);
        if (covered > hostArea) {
          hostArea = covered;
          host = area;
        }
      }
      if (host == null) return;

      final width = math.min(window.width, host.width);
      final height = math.min(window.height, host.height);
      // A pixel of slack, so rounding in either DPI conversion cannot make
      // this fire on every metrics change forever.
      if (width >= window.width - 1 && height >= window.height - 1) return;

      AppLog.i(
        '[WindowFit] window ${window.width.round()}x${window.height.round()}px '
        'exceeds the work area of its display '
        '(${host.width.round()}x${host.height.round()}px) — shrinking',
      );
      // Back into the app view's logical space, which is what setSize takes.
      await windowManager.setSize(Size(width / dpr, height / dpr));
    } catch (e) {
      // A display query that fails is not a reason to disturb the window.
      AppLog.w('[WindowFit] could not re-fit after a metrics change ($e)');
    } finally {
      _busy = false;
    }
  }
}
