import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../providers/auto_download_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/app_logger.dart';
import '../../utils/feedback_utils.dart';
import '../../widgets/common/section_header.dart';
import 'settings_tiles.dart';
import '../../utils/media_quality.dart';

class SettingsAppearanceTab extends ConsumerWidget {
  const SettingsAppearanceTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final settings = ref.watch(settingsProvider);

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenPadding),
      children: [
        // Theme: MediaHub is dark-only — the editorial palette doesn't
        // have a light variant. Theme picker intentionally absent.

        // Update Interval
        const SettingsSectionHeader(
          title: 'Refresh Rate',
          icon: Icons.timer_rounded,
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
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.update_rounded,
                    color: theme.colorScheme.onSecondaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Update Interval',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        'How often to refresh torrent data',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: appColors.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                DropdownButton<int>(
                  value: settings.updateIntervalSeconds,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  items: [1, 2, 3, 5, 10].map((seconds) {
                    return DropdownMenuItem(
                      value: seconds,
                      child: Text('$seconds sec'),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      ref
                          .read(settingsProvider.notifier)
                          .setUpdateInterval(value);
                    }
                  },
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Playback Settings (Stremio-inspired)
        const SettingsSectionHeader(
          title: 'Playback',
          icon: Icons.play_circle_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                SettingsSwitchTile(
                  icon: Icons.queue_play_next_rounded,
                  title: 'Binge Watching',
                  subtitle: 'Auto-play next episode when current ends',
                  value: settings.bingeWatchingEnabled,
                  onChanged: (value) {
                    ref
                        .read(settingsProvider.notifier)
                        .setBingeWatchingEnabled(value);
                  },
                ),
                if (settings.bingeWatchingEnabled) ...[
                  const Divider(height: AppSpacing.lg),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(
                          Icons.timer_rounded,
                          color: theme.colorScheme.onSecondaryContainer,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Countdown Duration',
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Seconds before episode ends to show popup',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: appColors.mutedText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      DropdownButton<int>(
                        value: settings.nextEpisodeCountdownSeconds,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        items: [15, 20, 30, 45, 60].map((seconds) {
                          return DropdownMenuItem(
                            value: seconds,
                            child: Text('$seconds sec'),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .setNextEpisodeCountdownSeconds(value);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Auto-Download Settings (Smart Queue)
        const SettingsSectionHeader(
          title: 'Smart Auto-Download',
          icon: Icons.download_for_offline_rounded,
        ),
        const _AutoDownloadCard(),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Advanced Polling Settings
        const SettingsSectionHeader(
          title: 'Advanced',
          icon: Icons.tune_rounded,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: Column(
              children: [
                SettingsSwitchTile(
                  icon: Icons.auto_mode_rounded,
                  title: 'Adaptive Polling',
                  subtitle: 'Reduce refresh rate when no downloads are active',
                  value: settings.useAdaptivePolling,
                  onChanged: (value) {
                    ref
                        .read(settingsProvider.notifier)
                        .setUseAdaptivePolling(value);
                  },
                ),
                if (settings.useAdaptivePolling) ...[
                  const Divider(height: AppSpacing.lg),
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Icon(
                          Icons.hourglass_empty_rounded,
                          color: theme.colorScheme.onSecondaryContainer,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Idle Refresh Interval',
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Refresh rate when no active downloads',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: appColors.mutedText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      DropdownButton<int>(
                        value: settings.idlePollingIntervalSeconds,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        items: [5, 10, 15, 30, 60].map((seconds) {
                          return DropdownMenuItem(
                            value: seconds,
                            child: Text('$seconds sec'),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            ref
                                .read(settingsProvider.notifier)
                                .setIdlePollingInterval(value);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sectionSpacing),

        // Diagnostics
        const SettingsSectionHeader(
          title: 'Diagnostics',
          icon: Icons.article_outlined,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.cardPadding),
            child: const _LogFileTile(),
          ),
        ),
      ],
    );
  }
}

class _AutoDownloadCard extends ConsumerWidget {
  const _AutoDownloadCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final autoDownloadState = ref.watch(autoDownloadProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SettingsSwitchTile(
              icon: Icons.smart_display_rounded,
              title: 'Auto-Download Next Episode',
              subtitle:
                  'Automatically queue next episode based on watch progress',
              value: autoDownloadState.enabled,
              onChanged: (value) {
                ref.read(autoDownloadProvider.notifier).setEnabled(value);
              },
            ),
            if (autoDownloadState.enabled) ...[
              const Divider(height: AppSpacing.lg),

              // Quality preference
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Icon(
                      Icons.high_quality_rounded,
                      color: theme.colorScheme.onSecondaryContainer,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Default Quality',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          'Preferred quality for auto-downloads',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: appColors.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  DropdownButton<String>(
                    // Normalised, not raw: a preference persisted as `4K` by
                    // an older build is not in `items`, and DropdownButton
                    // asserts on a value it cannot find.
                    value: MediaQuality.labelFor(
                      autoDownloadState.defaultQuality,
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    items:
                        [
                          MediaQuality.uhd.label,
                          MediaQuality.fullHd.label,
                          MediaQuality.hd.label,
                          MediaQuality.sd.label,
                        ].map((quality) {
                          return DropdownMenuItem(
                            value: quality,
                            child: Text(quality),
                          );
                        }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        ref
                            .read(autoDownloadProvider.notifier)
                            .setDefaultQuality(value);
                      }
                    },
                  ),
                ],
              ),

              const SizedBox(height: AppSpacing.md),

              // Download on progress
              SettingsSwitchTile(
                icon: Icons.play_arrow_rounded,
                title: 'Download While Watching',
                subtitle:
                    'Start download when current episode reaches threshold',
                value: autoDownloadState.downloadOnProgress,
                onChanged: (value) {
                  ref
                      .read(autoDownloadProvider.notifier)
                      .setDownloadOnProgress(value);
                },
              ),

              if (autoDownloadState.downloadOnProgress) ...[
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Icon(
                        Icons.percent_rounded,
                        color: theme.colorScheme.onTertiaryContainer,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Progress Threshold',
                            style: theme.textTheme.titleMedium,
                          ),
                          Text(
                            'Download next when ${(autoDownloadState.progressThreshold * 100).toInt()}% watched',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: appColors.mutedText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 120,
                      child: Slider(
                        value: autoDownloadState.progressThreshold,
                        min: 0.5,
                        max: 0.95,
                        divisions: 9,
                        label:
                            '${(autoDownloadState.progressThreshold * 100).toInt()}%',
                        onChanged: (value) {
                          ref
                              .read(autoDownloadProvider.notifier)
                              .setProgressThreshold(value);
                        },
                      ),
                    ),
                  ],
                ),
              ],

              const Divider(height: AppSpacing.lg),

              // Info about smart matching
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withAlpha(
                    AppOpacity.light,
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      color: theme.colorScheme.primary,
                      size: 18,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'Quality automatically matches your current episode. Handles season transitions and checks episode availability.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LogFileTile extends StatelessWidget {
  const _LogFileTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final path = AppLog.filePath;

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(
            Icons.description_outlined,
            color: theme.colorScheme.onSecondaryContainer,
            size: 20,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Application Log', style: theme.textTheme.titleMedium),
              Text(
                path ?? 'Unavailable — the log file could not be opened',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: appColors.mutedText,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (path != null)
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (!context.mounted) return;
              AppSnackBar.showInfo(context, message: 'Log path copied');
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy path'),
          ),
      ],
    );
  }
}
