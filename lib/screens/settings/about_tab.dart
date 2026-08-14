import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../utils/constants.dart';
import '../../widgets/common/section_header.dart';
import 'settings_tiles.dart';

class SettingsAboutTab extends ConsumerWidget {
  const SettingsAboutTab({super.key, required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        // App Info
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.tertiary,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withAlpha(
                          AppOpacity.medium,
                        ),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.bolt_rounded,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'MediaHub',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                  child: Text(
                    'Version ${AppConstants.appVersion}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'A modern torrent client for watching TV shows',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: appColors.mutedText,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Keyboard Shortcuts
        const SettingsSectionHeader(
          title: 'Keyboard Shortcuts',
          icon: Icons.keyboard_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                SettingsShortcutRow(action: 'Play/Pause', shortcut: 'Space'),
                const Divider(height: AppSpacing.lg),
                SettingsShortcutRow(action: 'Seek Forward 10s', shortcut: '→'),
                const Divider(height: AppSpacing.lg),
                SettingsShortcutRow(action: 'Seek Backward 10s', shortcut: '←'),
                const Divider(height: AppSpacing.lg),
                SettingsShortcutRow(action: 'Volume Up', shortcut: '↑'),
                const Divider(height: AppSpacing.lg),
                SettingsShortcutRow(action: 'Volume Down', shortcut: '↓'),
                const Divider(height: AppSpacing.lg),
                SettingsShortcutRow(action: 'Toggle Fullscreen', shortcut: 'F'),
                const Divider(height: AppSpacing.lg),
                SettingsShortcutRow(action: 'Mute/Unmute', shortcut: 'M'),
                const Divider(height: AppSpacing.lg),
                SettingsShortcutRow(action: 'Exit Player', shortcut: 'Esc'),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Reset
        const SettingsSectionHeader(
          title: 'Reset',
          icon: Icons.restart_alt_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: appColors.errorState.withAlpha(AppOpacity.light),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.restart_alt_rounded,
                    color: appColors.errorState,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reset to Defaults',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'Reset all settings to default values',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: appColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Reset'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: appColors.errorState,
                  ),
                  onPressed: onReset,
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.xxl),
      ],
    );
  }
}
