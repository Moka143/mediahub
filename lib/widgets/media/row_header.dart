import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../common/hub_pressable.dart';
import '../editorial/editorial.dart';

/// Heading over a row or grid of titles: serif title, an optional mono
/// note beside it (a count, "airs today"), and an optional "See all" link.
///
/// Home and the Library each had their own; the Library's was a Material
/// pill that matched nothing else on the page.
class RowHeader extends StatelessWidget {
  const RowHeader({
    super.key,
    required this.title,
    this.note,
    this.onSeeAll,
    this.seeAllLabel = 'See all',
    this.size = AppType.sizeTitle,
  });

  final String title;
  final String? note;
  final VoidCallback? onSeeAll;
  final String seeAllLabel;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: SerifTitle(title, size: size, height: 1.0, maxLines: 1),
        ),
        if (note != null) ...[
          const SizedBox(width: AppSpacing.md),
          MonoLabel(note!, color: AppColors.fg2, letterSpacing: 0.1),
        ],
        const Spacer(),
        if (onSeeAll != null)
          HubPressable(
            onTap: onSeeAll,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: Text(
                '$seeAllLabel →',
                style: AppType.mono(
                  size: AppType.sizeSmall,
                  color: AppColors.fg1,
                  letterSpacing: 0.06,
                  weight: FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
