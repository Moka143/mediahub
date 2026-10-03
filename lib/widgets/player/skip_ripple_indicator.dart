import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Netflix-style ±10s skip ripple shown over the video.
///
/// Animates once, on mount. Give each press its own key to replay it — see
/// `PlayerOverlayStack.skipTick`.
class SkipRippleIndicator extends StatefulWidget {
  final bool forward;

  const SkipRippleIndicator({super.key, required this.forward});

  @override
  State<SkipRippleIndicator> createState() => _SkipRippleIndicatorState();
}

class _SkipRippleIndicatorState extends State<SkipRippleIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AppDuration.slow);
    _scale = Tween<double>(
      begin: 0.7,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.0), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_ctrl);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = Text(
      '10s',
      style: AppType.ui(
        size: AppType.sizeHeading,
        color: AppColors.onMedia,
        weight: FontWeight.w700,
        height: 1.0,
      ),
    );
    final icon = Icon(
      widget.forward ? Icons.forward_10_rounded : Icons.replay_10_rounded,
      color: AppColors.onMedia,
      size: AppIconSize.xxl,
    );
    const gap = SizedBox(width: AppSpacing.xs);

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        return Opacity(
          opacity: _opacity.value,
          child: Transform.scale(scale: _scale.value, child: child),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppColors.mediaBlack.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadius.xl),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: widget.forward ? [label, gap, icon] : [icon, gap, label],
        ),
      ),
    );
  }
}
