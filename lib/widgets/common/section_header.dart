import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_typography.dart';

/// Settings section header — small uppercase mono label, accent color.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.padding,
  });

  final String title;
  final IconData? icon;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          padding ??
          const EdgeInsets.only(left: 20, right: 20, top: 28, bottom: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: AppColors.accent),
            const SizedBox(width: 8),
          ],
          Text(
            title.toUpperCase(),
            style: AppType.mono(
              size: 10,
              color: AppColors.accent,
              letterSpacing: 0.14,
              weight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
