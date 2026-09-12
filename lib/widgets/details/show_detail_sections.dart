import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Generic titled section block used for Storyline / Quick facts /
/// other info groups on the show details page.
class InfoSection extends StatelessWidget {
  const InfoSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: AppType.mono(
            size: 11,
            color: AppColors.fg2,
            weight: FontWeight.w700,
            letterSpacing: 0.08,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        child,
      ],
    );
  }
}
