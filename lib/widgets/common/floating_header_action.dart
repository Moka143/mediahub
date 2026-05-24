import 'package:flutter/material.dart';

import '../../design/app_colors.dart';

/// Circular glass-fill IconButton overlaid on a hero artwork.
///
/// Used in the floating top-left back button and top-right
/// favorite/watchlist/settings cluster on details screens. Backed by
/// `AppColors.glassFill` so the alpha matches across all 8 sites
/// without hand-typed `Colors.white.withAlpha(20)` literals.
class FloatingHeaderAction extends StatelessWidget {
  const FloatingHeaderAction({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final VoidCallback onPressed;
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
