import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../utils/formatters.dart';
import '../common/editorial_dialog_shell.dart';
import '../editorial/editorial.dart';

/// Full-screen prompt asking whether to resume from the last position.
///
/// Drawn with the app's editorial dialog chrome rather than Material's
/// `Card` and filled buttons, which made it the one dialog in the app that
/// looked like a different product.
class ResumePrompt extends StatelessWidget {
  final Duration resumePosition;
  final VoidCallback onStartOver;
  final VoidCallback onResume;

  const ResumePrompt({
    super.key,
    required this.resumePosition,
    required this.onStartOver,
    required this.onResume,
  });

  static const double _maxWidth = 380;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.mediaBlack.withValues(alpha: 0.87),
      child: EditorialDialogShell(
        maxWidth: _maxWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SerifTitle('Resume playback?', size: AppType.sizeTitle),
            const SizedBox(height: AppSpacing.sm),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'You stopped at '),
                  TextSpan(
                    text: Formatters.formatPlaybackDuration(resumePosition),
                    style: AppType.mono(
                      size: AppType.sizeBody,
                      color: AppColors.fg,
                    ),
                  ),
                  const TextSpan(text: '.'),
                ],
              ),
              style: AppType.ui(size: AppType.sizeLead, color: AppColors.fg1),
            ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                EditorialButton(
                  label: 'Start over',
                  icon: Icons.replay_rounded,
                  kind: EditorialButtonKind.ghost,
                  onPressed: onStartOver,
                ),
                const SizedBox(width: AppSpacing.sm),
                EditorialButton(
                  label: 'Resume',
                  icon: Icons.play_arrow_rounded,
                  kind: EditorialButtonKind.accent,
                  onPressed: onResume,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
