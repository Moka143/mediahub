import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Scales the whole UI down when — and only when — the logical viewport is
/// smaller than the layout's design floor.
///
/// Why this exists: on Windows the logical viewport is the panel divided by
/// the display scale, so a 1920x1080 monitor at 225% hands Flutter an 853x432
/// viewport and at 300% a 640x312 one. Every breakpoint, every fixed row
/// height and every grid ratio in this app was written against 800x600 or
/// more, so below that they do not degrade — they clip, and the 900px sidebar
/// gate in `MainNavigationScreen` swaps the desktop chrome for a phone layout.
///
/// Rather than teaching forty widgets about DPI, this gives them back the
/// viewport they expect and shrinks the result to fit. The app *is* smaller in
/// millimetres at that point, but it is smaller because the user asked Windows
/// to make everything 2.25x bigger than the panel can hold — and the
/// alternative is a window that does not fit its own screen.
///
/// Critically, [scaleFor] returns exactly 1.0 for any viewport at or above the
/// floor, and this widget then returns [child] untouched — no `FittedBox`, no
/// `MediaQuery` override, no extra layer in the tree at all. At 100% and 150%
/// display scale the widget tree is identical to what it was before this
/// existed, which is the whole point: nothing gets smaller on a normal screen.
class UiScale extends StatelessWidget {
  const UiScale({super.key, required this.designFloor, required this.child});

  /// The smallest logical viewport the layout is designed for.
  final Size designFloor;

  final Widget child;

  /// Never shrink past this. Below half size the UI stops being readable, and
  /// a window that small is already under the OS minimum
  /// (`AppConstants.hardMinWindowWidth`), so in practice the clamp is a safety
  /// net rather than a reachable state.
  static const double minScale = 0.5;

  /// When the UI is already being shrunk, cap runaway accessibility text.
  ///
  /// Windows' "Make text bigger" goes to 225% and is *independent* of the
  /// display scale, so a cramped viewport can arrive with 2.25x text on top of
  /// everything else. This cap applies ONLY in the scaled branch: at a normal
  /// viewport the user's text size is passed through untouched, because
  /// silently overriding an accessibility preference is not something a layout
  /// bug gets to do.
  static const double crampedMaxTextScale = 1.3;

  /// The factor to render at, given [viewport]. 1.0 means "no scaling".
  @visibleForTesting
  static double scaleFor(Size viewport, Size designFloor) {
    if (viewport.isEmpty ||
        !viewport.width.isFinite ||
        !viewport.height.isFinite) {
      return 1.0;
    }
    final fit = math.min(
      viewport.width / designFloor.width,
      viewport.height / designFloor.height,
    );
    // Never scale *up*: a 4K viewport at 100% must keep rendering at 1.0, or
    // the design would grow on large monitors, which nobody asked for.
    return fit >= 1.0 ? 1.0 : math.max(minScale, fit);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final scale = scaleFor(mq.size, designFloor);

    // The overwhelmingly common path, including every 100–150% display.
    if (scale >= 1.0) return child;

    final inverse = 1 / scale;
    final logicalSize = Size(mq.size.width * inverse, mq.size.height * inverse);

    return MediaQuery(
      // Everything measured in logical pixels has to grow by the same factor,
      // or widgets that read padding or insets land in the wrong place.
      data: mq.copyWith(
        size: logicalSize,
        padding: mq.padding * inverse,
        viewPadding: mq.viewPadding * inverse,
        viewInsets: mq.viewInsets * inverse,
        textScaler: mq.textScaler.clamp(maxScaleFactor: crampedMaxTextScale),
      ),
      // FittedBox, not Transform.scale. A Transform hands its child the
      // window's own tight constraints, and a SizedBox(logicalSize) under
      // tight constraints is clamped straight back to the window — so the
      // app was laid out at 853x432, then painted at 0.72 into the top-left
      // 72% of the window, while every breakpoint read the 1185x600 above.
      // FittedBox lays its child out unconstrained, so the SizedBox gets
      // exactly the logical size, and then scales the result to fill the
      // window: the aspect ratios match by construction, so `contain` and
      // `fill` agree. Pointer events are mapped back through the same
      // transform, so clicks land where they look — including in the
      // bottom-right corner, which an OverflowBox-in-Transform would miss.
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(size: logicalSize, child: child),
      ),
    );
  }
}
