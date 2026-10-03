import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial_led.dart';

/// Mono count pill for a navigation entry — active transfers, errors.
///
/// The one count badge: the sidebar draws it inline after the label, and
/// [NavBadge] pins it to an icon in the collapsed sidebar and the bottom
/// bar. There used to be two implementations that had drifted apart.
class NavCountTag extends StatelessWidget {
  const NavCountTag({
    super.key,
    required this.count,
    this.isError = false,
    this.filled = false,
  });

  final int count;

  /// Draw it in the error colour.
  final bool isError;

  /// A solid pill, for sitting on top of an icon where a translucent one
  /// would be unreadable. Inline after a label it stays translucent.
  final bool filled;

  /// 5, off the 4/8 steps: the sidebar's inline tag used 6 and the icon
  /// badge 4 before they were merged into this one pill.
  static const double _padH = 5;

  @override
  Widget build(BuildContext context) {
    final tone = isError ? AppColors.err : AppColors.accent;
    final (bg, fg) = filled
        ? (tone, AppColors.onAccent)
        : (AppColors.line, isError ? AppColors.err : AppColors.fg2);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: _padH,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.xxs),
      ),
      constraints: const BoxConstraints(minWidth: 18),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: AppType.mono(
          size: AppType.minSize,
          color: fg,
          weight: filled ? FontWeight.w700 : FontWeight.w500,
          height: 1.1,
          letterSpacing: 0.04,
        ),
      ),
    );
  }
}

/// Small accent LED for a navigation entry — something airing today, an
/// auto-download running. [pulse] breathes it while work is in progress.
///
/// Respects `TickerMode`, so a pulsing dot on a hidden tab or a covered
/// route stops asking for frames.
class NavStatusDot extends StatefulWidget {
  const NavStatusDot({
    super.key,
    this.pulse = false,
    this.color = AppColors.accent,
  });

  final bool pulse;
  final Color color;

  @override
  State<NavStatusDot> createState() => _NavStatusDotState();
}

class _NavStatusDotState extends State<NavStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AppDuration.pulse,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant NavStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.pulse && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 1;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => EditorialLed(
        color: widget.color.withValues(alpha: 0.55 + 0.45 * _ctrl.value),
        size: 6,
      ),
    );
  }
}

/// [NavCountTag] pinned to the top-right corner of a navigation icon.
/// Shows nothing extra while [count] is 0.
class NavBadge extends StatelessWidget {
  const NavBadge({
    super.key,
    required this.child,
    required this.count,
    this.isError = false,
  });

  /// The icon to badge.
  final Widget child;
  final int count;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -10,
          top: -6,
          child: NavCountTag(count: count, isError: isError, filled: true),
        ),
      ],
    );
  }
}

/// [NavStatusDot] pinned to the top-right corner of a navigation icon.
class NavDot extends StatelessWidget {
  const NavDot({
    super.key,
    required this.child,
    required this.isVisible,
    this.pulse = false,
  });

  final Widget child;
  final bool isVisible;

  /// Breathe the dot. It used to be accepted and ignored, so the calendar
  /// dot never pulsed in the bottom bar.
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    if (!isVisible) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(right: -3, top: -2, child: NavStatusDot(pulse: pulse)),
      ],
    );
  }
}
