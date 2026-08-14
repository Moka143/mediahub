import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';

/// Netflix-style ±10s skip ripple shown over the video.
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
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
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
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Opacity(
          opacity: _opacity.value,
          child: Transform.scale(
            scale: _scale.value,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.50),
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.forward) ...[
                    Icon(
                      Icons.replay_10_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '10s',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ] else ...[
                    const Text(
                      '10s',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.forward_10_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
