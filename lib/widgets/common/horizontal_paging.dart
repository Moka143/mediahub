import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';

/// Scroll arrows and edge fades for a horizontal scroller: which ends have
/// more past them, a page move to reach it, and a fade on those ends.
///
/// A mouse wheel scrolls a page vertically, so on desktop a row that runs
/// past the window edge can only be reached with these — and without a fade
/// the cut-off card read as a layout bug. `HoverScrollRow` and the episode
/// `NumberStrip` share this; they differ only in how they draw the arrows.
///
/// Give [pagingController] to the scroller, and wrap the scroller in
/// [trackEdges].
mixin HorizontalPaging<T extends StatefulWidget> on State<T> {
  final ScrollController pagingController = ScrollController();

  /// There is more content before the visible part.
  bool canScrollBack = false;

  /// There is more content after the visible part.
  bool canScrollForward = false;

  @override
  void initState() {
    super.initState();
    pagingController.addListener(_syncEdges);
    // The first frame has no scroll metrics yet, so a scroller that has not
    // been touched would never find out it overflows.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncEdges());
  }

  @override
  void dispose() {
    pagingController.dispose();
    super.dispose();
  }

  void _syncEdges() {
    if (!mounted || !pagingController.hasClients) return;
    final position = pagingController.position;
    final back = position.pixels > 1;
    final forward = position.pixels < position.maxScrollExtent - 1;
    if (back != canScrollBack || forward != canScrollForward) {
      setState(() {
        canScrollBack = back;
        canScrollForward = forward;
      });
    }
  }

  /// Scroll by [step] pixels, or by default by most of the visible width —
  /// so what was cut off at the edge is the first thing in view.
  void page({required bool forward, double? step}) {
    if (!pagingController.hasClients) return;
    final position = pagingController.position;
    final distance = step ?? position.viewportDimension * 0.85;
    unawaited(
      pagingController.animateTo(
        (position.pixels + (forward ? distance : -distance)).clamp(
          0.0,
          position.maxScrollExtent,
        ),
        duration: AppDuration.normal,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// [scroller], kept in step with metrics that change without a scroll —
  /// a window resize, items arriving — and, with [fade], faded over
  /// [fadeExtent] on each end that has more past it.
  ///
  /// The mask stays in the tree when neither end fades: wrapping and
  /// unwrapping the scroller would remount it and lose its position.
  Widget trackEdges(
    Widget scroller, {
    bool fade = true,
    double fadeExtent = 48,
  }) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _syncEdges();
        return false;
      },
      child: !fade
          ? scroller
          : ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) {
                final edge = (fadeExtent / bounds.width).clamp(0.0, 0.5);
                return LinearGradient(
                  colors: [
                    canScrollBack ? Colors.transparent : Colors.white,
                    Colors.white,
                    Colors.white,
                    canScrollForward ? Colors.transparent : Colors.white,
                  ],
                  stops: [0, edge, 1 - edge, 1],
                ).createShader(bounds);
              },
              child: scroller,
            ),
    );
  }
}
