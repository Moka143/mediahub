import 'package:flutter/material.dart';

import '../../design/app_colors.dart';

/// Circular glass-fill IconButton overlaid on a hero artwork.
///
/// Used in the floating top-left back button and top-right
/// favorite/watchlist/settings cluster on details screens. Backed by
/// `AppColors.glassFill` so the alpha matches across all 8 sites
/// without each one typing its own 8% white.
class FloatingHeaderAction extends StatelessWidget {
  const FloatingHeaderAction({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconColor = AppColors.fg,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// Also the button's accessible name — an icon has no text of its own, so
  /// leave it out only when something else labels the action.
  final String? tooltip;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.glassFill,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: iconColor),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}
