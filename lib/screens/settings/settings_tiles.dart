import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../widgets/common/section_header.dart';

/// The scrollable body of a Settings tab.
///
/// Centred and capped in width with the same gutter on both sides: the tabs
/// used to pad the list by 20px and the section headers by another 20px on
/// the left only, so content sat 50px from the left edge and 20px from the
/// right, and stretched across the whole of a wide window.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.children});

  final List<Widget> children;

  static const double maxContentWidth = 760;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = constraints.maxWidth > maxContentWidth + 48
            ? (constraints.maxWidth - maxContentWidth) / 2
            : AppSpacing.xxl;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            gutter,
            AppSpacing.sm,
            gutter,
            AppSpacing.huge,
          ),
          children: children,
        );
      },
    );
  }
}

/// A titled group of settings: the mono section header and a card.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.footer,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  /// Plain text under the card — what the section affects, caveats.
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionHeader(title: title, icon: icon),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xs,
              top: AppSpacing.sm,
              right: AppSpacing.xs,
            ),
            child: Text(footer!, style: AppType.caption()),
          ),
      ],
    );
  }
}

/// The 40×40 tinted glyph at the start of a settings row.
class SettingsIconBox extends StatelessWidget {
  const SettingsIconBox({super.key, required this.icon, this.active = false});

  final IconData icon;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: active ? AppColors.accentSoft : AppColors.bgSurfaceHi,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(
        icon,
        color: active ? AppColors.accent : AppColors.fg2,
        size: AppIconSize.md,
      ),
    );
  }
}

/// A row with an on/off switch. The whole row toggles it — click, or Space
/// with the row focused — and it is announced once, as a switch with its
/// title and explanation.
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
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      // The same gap as the other rows, so every title starts at one edge
      // (ListTile's default is 16).
      horizontalTitleGap: AppSpacing.md,
      secondary: SettingsIconBox(icon: icon, active: value),
      title: Text(title, style: AppType.bodyStrong()),
      subtitle: Text(subtitle, style: AppType.caption()),
    );
  }
}

/// A row that picks one value from a short list.
class SettingsDropdownTile<T> extends StatelessWidget {
  const SettingsDropdownTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SettingsIconBox(icon: icon),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppType.bodyStrong()),
              Text(subtitle, style: AppType.caption()),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        DropdownButton<T>(
          value: value,
          borderRadius: BorderRadius.circular(AppRadius.md),
          underline: const SizedBox.shrink(),
          items: [
            for (final option in options)
              DropdownMenuItem(value: option, child: Text(labelOf(option))),
            // A value saved by another build, or typed into the prefs, that
            // is not one of the options: list it rather than trip
            // DropdownButton's assertion and blank the whole tab.
            if (!options.contains(value))
              DropdownMenuItem(value: value, child: Text(labelOf(value))),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

/// One shortcut in a keyboard reference: what it does, then its key caps.
class SettingsShortcutRow extends StatelessWidget {
  final String action;
  final List<String> keys;

  const SettingsShortcutRow({
    super.key,
    required this.action,
    required this.keys,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(child: Text(action, style: AppType.body())),
          const SizedBox(width: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final key in keys)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.bgSurfaceHi,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                    border: Border.all(color: AppColors.lineStrong),
                  ),
                  child: Text(
                    key,
                    style: AppType.mono(
                      size: AppType.sizeCaption,
                      color: AppColors.fg,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
