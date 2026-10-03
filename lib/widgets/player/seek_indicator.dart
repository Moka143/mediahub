import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../utils/formatters.dart';

/// Overlay shown while the user is dragging horizontally to seek.
class SeekIndicator extends StatelessWidget {
  final double seekDelta;
  final Duration dragStartTime;

  const SeekIndicator({
    super.key,
    required this.seekDelta,
    required this.dragStartTime,
  });

  @override
  Widget build(BuildContext context) {
    final isForward = seekDelta >= 0;
    final seconds = seekDelta.abs().round();
    final targetTime = dragStartTime + Duration(seconds: seekDelta.round());

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: AppColors.mediaBlack.withValues(alpha: 0.87),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isForward ? Icons.forward_rounded : Icons.replay_rounded,
                color: AppColors.onMedia,
                size: AppIconSize.xl,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${isForward ? '+' : '-'}${seconds}s',
                style: AppType.mono(
                  size: AppType.sizeTitle,
                  color: AppColors.onMedia,
                  weight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            Formatters.formatPlaybackDuration(
              targetTime.isNegative ? Duration.zero : targetTime,
            ),
            style: AppType.mono(
              size: AppType.sizeSubhead,
              color: AppColors.onMediaMuted,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
  }
}
