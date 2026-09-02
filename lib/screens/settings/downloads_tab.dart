import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/common/section_header.dart';
import 'settings_tiles.dart';

class SettingsDownloadsTab extends ConsumerWidget {
  const SettingsDownloadsTab({
    super.key,
    required this.downloadLimitController,
    required this.uploadLimitController,
    required this.onApplyDownloadLimit,
    required this.onApplyUploadLimit,
  });

  final TextEditingController downloadLimitController;
  final TextEditingController uploadLimitController;
  final ValueChanged<int> onApplyDownloadLimit;
  final ValueChanged<int> onApplyUploadLimit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final settings = ref.watch(settingsProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        // Save Location
        const SettingsSectionHeader(
          title: 'Save Location',
          icon: Icons.folder_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(
                        color: theme.colorScheme.outline.withAlpha(
                          AppOpacity.light,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.folder_rounded, color: appColors.mutedText),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Default Save Path',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: appColors.mutedText,
                                ),
                              ),
                              Text(
                                settings.defaultSavePath,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Browse'),
                  onPressed: () async {
                    final result = await FilePicker.platform.getDirectoryPath();
                    if (result != null) {
                      await ref
                          .read(settingsProvider.notifier)
                          .setDefaultSavePath(result);
                    }
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Speed Limits
        const SettingsSectionHeader(
          title: 'Speed Limits',
          icon: Icons.speed_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: downloadLimitController,
                        decoration: InputDecoration(
                          labelText: 'Download Limit (KB/s)',
                          hintText: '0 = unlimited',
                          prefixIcon: Icon(
                            Icons.arrow_downward_rounded,
                            color: appColors.success,
                          ),
                          helperText: 'Leave empty for unlimited',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (value) {
                          final limit = int.tryParse(value) ?? 0;
                          final limitBytes = limit * 1024;
                          ref
                              .read(settingsProvider.notifier)
                              .setDownloadSpeedLimit(limitBytes);
                          onApplyDownloadLimit(limitBytes);
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: TextField(
                        controller: uploadLimitController,
                        decoration: InputDecoration(
                          labelText: 'Upload Limit (KB/s)',
                          hintText: '0 = unlimited',
                          prefixIcon: Icon(
                            Icons.arrow_upward_rounded,
                            color: theme.colorScheme.tertiary,
                          ),
                          helperText: 'Leave empty for unlimited',
                        ),
                        keyboardType: TextInputType.number,
                        onChanged: (value) {
                          final limit = int.tryParse(value) ?? 0;
                          final limitBytes = limit * 1024;
                          ref
                              .read(settingsProvider.notifier)
                              .setUploadSpeedLimit(limitBytes);
                          onApplyUploadLimit(limitBytes);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Behavior
        const SettingsSectionHeader(
          title: 'Behavior',
          icon: Icons.tune_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: SettingsSwitchTile(
              icon: Icons.stop_circle_outlined,
              title: 'Stop seeding on complete',
              subtitle: 'Automatically pause torrents when download finishes',
              value: settings.stopSeedingOnComplete,
              onChanged: (value) {
                ref
                    .read(settingsProvider.notifier)
                    .setStopSeedingOnComplete(value);
              },
            ),
          ),
        ),
      ],
    );
  }
}
