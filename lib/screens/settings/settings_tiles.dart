import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

class SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Semantics(
      toggled: value,
      label: '$title. $subtitle',
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: value
                  ? theme.colorScheme.primary.withAlpha(AppOpacity.light)
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              icon,
              color: value ? theme.colorScheme.primary : appColors.mutedText,
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: appColors.mutedText,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class SettingsShortcutRow extends StatelessWidget {
  final String action;
  final String shortcut;

  const SettingsShortcutRow({
    super.key,
    required this.action,
    required this.shortcut,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(action, style: theme.textTheme.bodyMedium),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: theme.colorScheme.outline.withAlpha(AppOpacity.light),
            ),
          ),
          child: Text(
            shortcut,
            style: AppType.mono(
              size: 13,
              color: AppColors.fg,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
