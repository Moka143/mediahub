import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';

/// A modern section header widget with consistent styling
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    this.onTap,
    this.padding,
    this.showDivider = false,
    this.large = false,
  });

  /// The title text for the section
  final String title;

  /// Optional leading icon
  final IconData? icon;

  /// Optional trailing widget (e.g., "See all" button, count badge)
  final Widget? trailing;

  /// Optional tap callback for the entire header
  final VoidCallback? onTap;

  /// Custom padding (defaults to horizontal screen padding)
  final EdgeInsetsGeometry? padding;

  /// Whether to show a divider above the header
  final bool showDivider;

  /// Whether to use large title style
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final content = Padding(
      padding: padding ??
          EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
            vertical: large ? AppSpacing.md : AppSpacing.sm,
          ),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withAlpha(AppOpacity.semi),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(
                icon,
                size: large ? AppIconSize.lg : AppIconSize.md,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Text(
              title,
              style: (large 
                  ? theme.textTheme.titleLarge
                  : theme.textTheme.titleMedium)?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );

    Widget result = onTap != null
        ? Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: content,
            ),
          )
        : content;

    if (showDivider) {
      result = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(
            height: 1,
            thickness: 1,
            color: theme.colorScheme.outlineVariant.withAlpha(AppOpacity.medium),
          ),
          result,
        ],
      );
    }

    return result;
  }
}

/// A modern section header designed for settings screens
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
    final theme = Theme.of(context);

    return Padding(
      padding: padding ??
          const EdgeInsets.only(
            left: AppSpacing.screenPadding,
            right: AppSpacing.screenPadding,
            top: AppSpacing.xxl,
            bottom: AppSpacing.md,
          ),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              padding: const EdgeInsets.all(AppSpacing.xs),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primary,
                    theme.colorScheme.tertiary,
                  ],
                ),
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: Icon(
                icon,
                size: AppIconSize.sm,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
