import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Standard surface color for all `PopupMenuButton`s in the app.
const Color kMediaHubPopupColor = AppColors.bgSurfaceHi;

/// Standard surface shape for `PopupMenuButton`s.
final ShapeBorder kMediaHubPopupShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(AppRadius.sm),
  side: const BorderSide(color: AppColors.line, width: 1),
);

/// Build a uniformly-styled child for a `PopupMenuItem`.
///
/// All popup-menu items across the app should use this so icon size,
/// label typography, destructive coloring, and spacing match.
Widget mediaHubMenuLabel({
  required IconData icon,
  required String label,
  bool destructive = false,
}) {
  final color = destructive ? AppColors.err : AppColors.fg1;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: AppSpacing.sm),
      Text(label, style: AppType.ui(size: 12, color: color)),
    ],
  );
}
