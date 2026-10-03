import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// A titled block under a details hero — "Overview", "Auto-download".
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
            size: AppType.sizeSmall,
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
