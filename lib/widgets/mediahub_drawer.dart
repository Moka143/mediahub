import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';

/// Shared scaffolding for the right-side drawers in the app
/// (MediaHubEpisodesDrawer, MediaHubTorrentDrawer).
///
/// Provides:
///   • Backdrop blur + animated dim — keeps the underlying screen visible
///     but de-emphasized while the drawer is open.
///   • Tap-outside-to-close.
///   • Drag-to-dismiss from a thin grab strip on the panel's left edge
///     (a wider gesture would fight the body's vertical scrolling).
///   • Esc-to-close.
///   • Single shared slide-in curve & timing (`Curves.fastOutSlowIn`,
///     `AppDuration.normal`).
///
/// Consumers supply only the panel body via [show]'s `builder`. The shell
/// owns the panel chrome (border, shadow, sizing, slide animation).
class MediaHubDrawer {
  /// Width of the drawer when the screen is wider than [_compactBreakpoint].
  /// On narrower screens we collapse to 96% of width.
  static const double _wideWidth = 580.0;

  /// Above this we show the wide layout, below we go nearly-fullwidth.
  static const double _compactBreakpoint = 720.0;

  /// Pixel width of the left-edge grab strip that initiates the drag-to-
  /// -dismiss gesture. Wider than this would fight with body scrolling /
  /// horizontal scrollables inside the panel.
  static const double dragGripWidth = 24.0;

  static double widthFor(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return w >= _compactBreakpoint ? _wideWidth : w * 0.96;
  }

  /// Slide a drawer in from the right. The drawer is pushed onto
  /// [Navigator] as a transparent route — its return value is the value
  /// passed to `Navigator.pop` from inside the panel.
  static Future<T?> show<T>({
    required BuildContext context,
    required WidgetBuilder builder,
  }) {
    return Navigator.of(context).push<T>(
      PageRouteBuilder<T>(
        opaque: false,
        // Barrier handled inside the shell (so we can fade the blur with
        // the same animation curve as the slide).
        barrierColor: Colors.transparent,
        barrierDismissible: false,
        transitionDuration: AppDuration.normal,
        reverseTransitionDuration: AppDuration.fast,
        pageBuilder: (ctx, anim, sec) => _MediaHubDrawerScaffold(
          anim: anim,
          child: Builder(builder: builder),
        ),
        // Slide + dim are both driven from inside the scaffold so they share
        // the same controller (and a manual drag offset can layer on top).
        transitionsBuilder: (_, anim, sec, child) => child,
      ),
    );
  }
}

class _MediaHubDrawerScaffold extends StatefulWidget {
  const _MediaHubDrawerScaffold({required this.anim, required this.child});

  final Animation<double> anim;
  final Widget child;

  @override
  State<_MediaHubDrawerScaffold> createState() =>
      _MediaHubDrawerScaffoldState();
}

class _MediaHubDrawerScaffoldState extends State<_MediaHubDrawerScaffold> {
  /// Pixels the user has dragged the drawer to the right. Combined with
  /// the slide-in animation: when at rest the panel sits at offset 0, mid
  /// drag at +N, beyond `width * 0.3` (or with a flick) we pop the route.
  double _dragOffset = 0.0;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final width = MediaHubDrawer.widthFor(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 1) Backdrop blur + dim. Fades alongside the slide animation so
          //    open/close feel like a single motion.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: widget.anim,
              builder: (_, __) {
                final t = widget.anim.value.clamp(0.0, 1.0);
                final dragFade = _dragging
                    ? (1 - (_dragOffset / width).clamp(0.0, 1.0))
                    : 1.0;
                final shown = t * dragFade;
                return BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 10 * shown,
                    sigmaY: 10 * shown,
                  ),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.45 * shown),
                  ),
                );
              },
            ),
          ),
          // 2) Tap-outside layer. Sits below the panel, above the blur, so
          //    a tap on the empty area dismisses without competing with the
          //    panel's own gestures.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          // 3) The panel itself, slid in from the right.
          Align(
            alignment: Alignment.centerRight,
            child: AnimatedBuilder(
              animation: widget.anim,
              builder: (_, child) {
                final t = Curves.fastOutSlowIn.transform(
                  widget.anim.value.clamp(0.0, 1.0),
                );
                final slideIn = (1 - t) * width;
                final dragSlide = _dragging ? _dragOffset : 0.0;
                return Transform.translate(
                  offset: Offset(slideIn + dragSlide, 0),
                  child: child,
                );
              },
              child: SizedBox(
                width: width,
                height: mq.size.height,
                child: Focus(
                  autofocus: true,
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.escape) {
                      Navigator.of(context).pop();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: GestureDetector(
                    // Absorb taps so panel content doesn't dismiss the route.
                    onTap: () {},
                    behavior: HitTestBehavior.opaque,
                    child: Stack(
                      children: [
                        // Panel chrome (border + shadow + body).
                        const Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.bgPageAlt,
                              border: Border(
                                left: BorderSide(
                                  color: Color(0x1AFFFFFF),
                                  width: 1,
                                ),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x80000000),
                                  blurRadius: 64,
                                  offset: Offset(-24, 0),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned.fill(child: widget.child),
                        // 4) Drag-to-dismiss grip on the left edge. Narrow
                        //    so it doesn't conflict with horizontal scroll
                        //    or buttons inside the body. Visually a 1px
                        //    accent line + a slightly wider invisible
                        //    hit-area.
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: MediaHubDrawer.dragGripWidth,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragStart: (_) => setState(() {
                              _dragging = true;
                              _dragOffset = 0;
                            }),
                            onHorizontalDragUpdate: (d) {
                              setState(() {
                                _dragOffset = (_dragOffset + d.delta.dx)
                                    .clamp(0.0, width);
                              });
                            },
                            onHorizontalDragEnd: (d) {
                              final flick =
                                  (d.primaryVelocity ?? 0) > 800;
                              final past = _dragOffset > width * 0.3;
                              if (flick || past) {
                                Navigator.of(context).pop();
                              } else {
                                setState(() {
                                  _dragging = false;
                                  _dragOffset = 0;
                                });
                              }
                            },
                            child: const _DrawerGrip(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Subtle visual affordance for the drag-to-dismiss grip strip.
class _DrawerGrip extends StatelessWidget {
  const _DrawerGrip();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 4,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: AppOpacity.light / 255.0),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
      ),
    );
  }
}
