import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Settings section header — small uppercase mono label, accent color.
///
/// No horizontal inset of its own: it lines up with the card under it, and
/// the page supplies the gutter. It used to add 20px on both sides on top of
/// the page's 20, which pushed every header in from the cards' left edge.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.padding = const EdgeInsets.only(top: _topGap, bottom: AppSpacing.md),
  });

  /// Space above a section — well over the 12 below it, so the header reads
  /// as part of the card under it, not the one above.
  static const double _topGap = 28;

  final String title;
  final IconData? icon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Semantics(
        header: true,
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: AppColors.accent),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: AppType.label(
                  color: AppColors.accent,
                ).copyWith(fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
