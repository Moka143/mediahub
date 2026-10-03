import 'dart:async';
import 'dart:io';
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
  bool _stopped = false;

  /// The invisible resize border Windows 10/11 draws outside a window's
  /// visible edge, in pixels at 100% scale.
  ///
  /// `GetWindowRect` — and so window_manager's bounds — includes it, on the
  /// left, right and bottom: a window snapped to fill a work area measures
  /// wider and taller than the area itself. Measured as `SM_CXSIZEFRAME +
  /// SM_CXPADDEDBORDER`, 4 + 4 px at 96 DPI with the default theme; it scales
  /// with the display. Without allowing for it this "fixed" every snapped and
  /// half-screen window, fighting the user.
  ///
  /// Not verified against a live Windows machine, so the allowance is
  /// deliberately generous — both sides' worth, in both directions. A window
  /// genuinely too big for its screen is too big by far more than this.
  static const double win32InvisibleBorder = 8;

  void start() {
    _stopped = false;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Stop watching. Called by the shutdown before it hides the window, so the
  /// metrics change that hiding causes cannot start a resize mid-teardown.
  void stop() {
    _stopped = true;
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeMetrics() {
    if (_stopped) return;
    // A drag across a monitor boundary emits a burst of these. Collapse them.
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_refit()),
    );
  }

  /// How much bigger than a work area a window may measure and still count
  /// as fitting it. See [win32InvisibleBorder].
  @visibleForTesting
  static double frameSlack({required bool windows, required double scale}) =>
      windows ? 2 * win32InvisibleBorder * scale + 1 : 1;

  /// The size [window] should shrink to so it fits the work area it mostly
  /// sits on, or null when it fits — within [slack] — already.
  ///
  /// Everything in one coordinate space: see [_refit] for which.
  @visibleForTesting
  static Size? shrinkToFit({
    required Rect window,
    required List<Rect> workAreas,
    required double slack,
  }) {
    Rect? host;
    var hostArea = 0.0;
    for (final area in workAreas) {
      final overlap = window.intersect(area);
      final covered =
          math.max(0.0, overlap.width) * math.max(0.0, overlap.height);
      if (covered > hostArea) {
        hostArea = covered;
        host = area;
      }
    }
    if (host == null) return null;

    final widthFits = window.width <= host.width + slack;
    final heightFits = window.height <= host.height + slack;
    if (widthFits && heightFits) return null;
    return Size(
      widthFits ? window.width : host.width,
      heightFits ? window.height : host.height,
    );
  }

  Future<void> _refit() async {
    if (_busy || _stopped) return;
    _busy = true;
    try {
      if (await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }

      // One coordinate space for both sides of the comparison.
      //
      // Windows: physical pixels. screen_retriever divides each display's
      // work area by *that display's* scale factor, while window_manager
      // divides bounds by the app view's devicePixelRatio — on a mixed-DPI
      // desktop those are two different logical spaces, so both are
      // multiplied back out.
      //
      // macOS: points, as reported. Every display shares one global space of
      // points, and multiplying each by its own backing scale — as this used
      // to everywhere — pulls a Retina laptop and a standard external
      // monitor apart into overlapping, meaningless rectangles.
      final windows = Platform.isWindows;
      final viewScale = windows
          ? ui.PlatformDispatcher.instance.views.first.devicePixelRatio
          : 1.0;
      final bounds = await windowManager.getBounds();
      final window = Rect.fromLTWH(
        bounds.left * viewScale,
        bounds.top * viewScale,
        bounds.width * viewScale,
        bounds.height * viewScale,
      );

      final areas = <Rect>[
        for (final display in await screenRetriever.getAllDisplays())
          () {
            final scale = windows ? (display.scaleFactor ?? 1).toDouble() : 1.0;
            final position = display.visiblePosition ?? Offset.zero;
            final size = display.visibleSize ?? display.size;
            return Rect.fromLTWH(
              position.dx * scale,
              position.dy * scale,
              size.width * scale,
              size.height * scale,
            );
          }(),
      ];

      final target = shrinkToFit(
        window: window,
        workAreas: areas,
        slack: frameSlack(windows: windows, scale: viewScale),
      );
      if (target == null || _stopped) return;

      AppLog.i(
        '[WindowFit] window ${window.width.round()}x${window.height.round()} '
        'exceeds the work area of its display — shrinking to '
        '${target.width.round()}x${target.height.round()}',
      );
      // Back into the app view's logical space, which is what setSize takes.
      await windowManager.setSize(
        Size(target.width / viewScale, target.height / viewScale),
      );
    } catch (e) {
      // A display query that fails is not a reason to disturb the window.
      AppLog.w('[WindowFit] could not re-fit after a metrics change ($e)');
    } finally {
      _busy = false;
    }
  }
}
