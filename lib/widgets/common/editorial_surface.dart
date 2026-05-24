import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// Editorial replacement for Material's `Card`.
///
/// Renders the bgSurface background + hairline border + rounded
/// corners. Use this anywhere the previous design called for a Card
/// so the settings screen and other elevated surfaces look like the
/// rest of the editorial chrome instead of Material 3 cards.
class EditorialSurface extends StatelessWidget {
  const EditorialSurface({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(AppSpacing.cardPadding),
    this.radius = AppRadius.lg,
  });

  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color ?? AppColors.bgSurface,
        border: Border.all(color: AppColors.line, width: 1),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
