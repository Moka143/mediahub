import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../providers/settings_provider.dart';
import 'settings_tiles.dart';

/// Settings → General: playback and how often Transfers refreshes.
///
/// This was the "Appearance" tab, which held no appearance settings at all
/// — MediaHub is dark-only by design, so there is no theme to pick. Its
/// auto-download card moved to Downloads and its diagnostics to About,
/// where the README already sends people for the log.
class SettingsGeneralTab extends ConsumerWidget {
  const SettingsGeneralTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return SettingsPage(
      children: [
        SettingsSection(
          title: 'Playback',
          icon: Icons.play_circle_rounded,
          children: [
            SettingsSwitchTile(
              icon: Icons.queue_play_next_rounded,
              title: 'Play the next episode automatically',
              subtitle:
                  'When an episode ends, count down and start the next one',
              value: settings.bingeWatchingEnabled,
              onChanged: (value) =>
                  unawaited(notifier.setBingeWatchingEnabled(value)),
            ),
            if (settings.bingeWatchingEnabled) ...[
              const Divider(height: AppSpacing.xl),
              SettingsDropdownTile<int>(
                icon: Icons.timer_rounded,
                title: 'Up next countdown',
                subtitle: 'How long before the end the next episode is offered',
                value: settings.nextEpisodeCountdownSeconds,
                options: const [15, 20, 30, 45, 60],
                labelOf: (s) => '$s sec',
                onChanged: (s) =>
                    unawaited(notifier.setNextEpisodeCountdownSeconds(s)),
              ),
            ],
          ],
        ),
        SettingsSection(
          title: 'Refresh',
          icon: Icons.update_rounded,
          footer:
              'How often MediaHub asks the torrent engine for progress. '
              'Longer intervals use less power.',
          children: [
            SettingsDropdownTile<int>(
              icon: Icons.update_rounded,
              title: 'Refresh transfers every',
              subtitle: 'While something is downloading',
              value: settings.updateIntervalSeconds,
              options: const [1, 2, 3, 5, 10],
              labelOf: (s) => '$s sec',
              onChanged: (s) => unawaited(notifier.setUpdateInterval(s)),
            ),
            const Divider(height: AppSpacing.xl),
            SettingsSwitchTile(
              icon: Icons.auto_mode_rounded,
              title: 'Slow down when idle',
              subtitle: 'Refresh less often when nothing is downloading',
              value: settings.useAdaptivePolling,
              onChanged: (value) =>
                  unawaited(notifier.setUseAdaptivePolling(value)),
            ),
            if (settings.useAdaptivePolling) ...[
              const Divider(height: AppSpacing.xl),
              SettingsDropdownTile<int>(
                icon: Icons.hourglass_empty_rounded,
                title: 'Refresh when idle every',
                subtitle: 'While nothing is downloading',
                value: settings.idlePollingIntervalSeconds,
                options: const [5, 10, 15, 30, 60],
                labelOf: (s) => '$s sec',
                onChanged: (s) => unawaited(notifier.setIdlePollingInterval(s)),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
