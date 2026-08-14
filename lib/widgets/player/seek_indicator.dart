import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black87,
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
                color: Colors.white,
                size: 28,
              ),
              const SizedBox(width: 8),
              Text(
                '${isForward ? '+' : '-'}${seconds}s',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            Formatters.formatPlaybackDuration(
              targetTime.isNegative ? Duration.zero : targetTime,
            ),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
