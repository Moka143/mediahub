import 'package:flutter/material.dart';

import '../../design/app_colors.dart';

/// 2–3px linear progress bar with the accent orange fill. Matches the
/// `.prog` and `.prog.thin` rules in the design's CSS.
///
/// Optionally pass [buffered] (0..1) to render an on-disk buffer
/// track behind the playhead — the editorial player overlay's
/// "honest seek bar" pattern. The dim track shows actual on-disk
/// progress so users can scrub safely.
class EditorialProgress extends StatelessWidget {
  const EditorialProgress({
    super.key,
    required this.value,
    this.buffered,
    this.thin = false,
    this.borderRadius = 2,
  });

  /// Progress 0..1.
  final double value;

  /// Optional buffered fraction 0..1. Rendered behind the main fill.
  final double? buffered;

  /// Use the 2px thin variant. Default is 3px.
  final bool thin;

  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final height = thin ? 2.0 : 3.0;
    final clamped = value.clamp(0.0, 1.0);
    final bufClamped = buffered?.clamp(0.0, 1.0);

    return SizedBox(
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: Colors.white.withValues(alpha: 0.1)),
            ),
            if (bufClamped != null)
              FractionallySizedBox(
                widthFactor: bufClamped,
                child: ColoredBox(color: Colors.white.withValues(alpha: 0.18)),
              ),
            FractionallySizedBox(
              widthFactor: clamped,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.4),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
