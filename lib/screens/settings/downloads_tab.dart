import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../providers/auto_download_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/settings_provider.dart';
import '../../utils/feedback_utils.dart';
import '../../utils/media_quality.dart';
import 'auto_download_activity.dart';
import 'settings_text_field.dart';
import 'settings_tiles.dart';
import 'settings_validation.dart';

/// Settings → Downloads: where files go, how fast, what happens when they
/// finish, and auto-download.
class SettingsDownloadsTab extends ConsumerWidget {
  const SettingsDownloadsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    // Saves finish after an await, and a field also saves as the page
    // closes; the container outlives this widget, a WidgetRef does not.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);

    Future<String?> saveLimit(String text, {required bool download}) async {
      final bytes = speedLimitBytes(text);
      if (download) {
        await notifier.setDownloadSpeedLimit(bytes);
      } else {
        await notifier.setUploadSpeedLimit(bytes);
      }
      await _applyLimitNow(container, messenger, bytes, download: download);
      return null;
    }

    return SettingsPage(
      children: [
        SettingsSection(
          title: 'Save location',
          icon: Icons.folder_rounded,
          footer: 'Library shows the videos in this folder.',
          children: [
            Row(
              children: [
                const SettingsIconBox(icon: Icons.folder_open_rounded),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Download folder', style: AppType.bodyStrong()),
                      Tooltip(
                        message: settings.defaultSavePath,
                        child: Text(
                          settings.defaultSavePath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.mono(
                            size: AppType.sizeCaption,
                            color: AppColors.fg2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                OutlinedButton.icon(
                  icon: const Icon(Icons.drive_folder_upload_rounded, size: 18),
                  label: const Text('Change…'),
                  onPressed: () async {
                    final folder = await FilePicker.platform.getDirectoryPath();
                    if (folder != null) {
                      await notifier.setDefaultSavePath(folder);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: 'Speed limits',
          icon: Icons.speed_rounded,
          footer: 'Leave a field empty for no limit.',
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SettingsTextField(
                    label: 'Download limit (KB/s)',
                    value: speedLimitText(settings.downloadSpeedLimit),
                    hint: 'No limit',
                    prefixIcon: Icons.arrow_downward_rounded,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: validateSpeedLimit,
                    onSave: (v) => saveLimit(v, download: true),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: SettingsTextField(
                    label: 'Upload limit (KB/s)',
                    value: speedLimitText(settings.uploadSpeedLimit),
                    hint: 'No limit',
                    prefixIcon: Icons.arrow_upward_rounded,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: validateSpeedLimit,
                    onSave: (v) => saveLimit(v, download: false),
                  ),
                ),
              ],
            ),
          ],
        ),
        SettingsSection(
          title: 'When a download finishes',
          icon: Icons.tune_rounded,
          children: [
            SettingsSwitchTile(
              icon: Icons.stop_circle_outlined,
              title: 'Stop sharing finished downloads',
              subtitle:
                  'Pause a torrent once it has downloaded, instead of '
                  'seeding it to other people',
              value: settings.stopSeedingOnComplete,
              onChanged: (value) =>
                  unawaited(notifier.setStopSeedingOnComplete(value)),
            ),
          ],
        ),
        const _AutoDownloadSection(),
        const SettingsSection(
          title: 'Recent auto-download activity',
          icon: Icons.history_rounded,
          children: [AutoDownloadActivity()],
        ),
      ],
    );
  }

  /// Push a just-saved limit to the running engine, where it can take one.
  ///
  /// An engine that takes rate limits as launch flags cannot apply one now.
  /// The value is already saved; showing a failure would claim the setting
  /// did not stick, and saying nothing would claim it took effect. Neither
  /// is true.
  static Future<void> _applyLimitNow(
    ProviderContainer container,
    ScaffoldMessengerState messenger,
    int bytes, {
    required bool download,
  }) async {
    if (!container.read(connectionProvider).isConnected) return;
    final engine = container.read(torrentEngineProvider);
    if (!engine.capabilities.liveSpeedLimits) {
      AppSnackBar.showOn(
        messenger,
        message:
            'Saved. The built-in engine applies speed limits when it next '
            'starts.',
      );
      return;
    }
    final applied = download
        ? await engine.setDownloadLimit(bytes)
        : await engine.setUploadLimit(bytes);
    if (!applied) {
      AppSnackBar.showOn(
        messenger,
        message:
            'Saved, but the engine didn\'t take the new '
            '${download ? 'download' : 'upload'} limit. Check the '
            'connection, then try again.',
        kind: AppSnackBarKind.error,
        actionLabel: 'Try again',
        onAction: () => unawaited(
          _applyLimitNow(container, messenger, bytes, download: download),
        ),
      );
    }
  }
}

class _AutoDownloadSection extends ConsumerWidget {
  const _AutoDownloadSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(autoDownloadProvider);
    final notifier = ref.read(autoDownloadProvider.notifier);
    final percent = (state.progressThreshold * 100).round();

    return SettingsSection(
      title: 'Auto-download',
      icon: Icons.download_for_offline_rounded,
      footer: state.enabled
          ? 'Quality follows the episode you are watching, and it carries on '
                'into the next season when one ends.'
          : null,
      children: [
        SettingsSwitchTile(
          icon: Icons.smart_display_rounded,
          title: 'Download next episodes',
          subtitle: 'Fetch the next episode of shows you are watching',
          value: state.enabled,
          onChanged: (value) => unawaited(notifier.setEnabled(value)),
        ),
        if (state.enabled) ...[
          const Divider(height: AppSpacing.xl),
          SettingsDropdownTile<String>(
            icon: Icons.high_quality_rounded,
            title: 'Preferred quality',
            subtitle: 'Used when a show has no quality of its own yet',
            // Normalised, not raw: a preference persisted as `4K` by an
            // older build is not among the options, and DropdownButton
            // asserts on a value it cannot find.
            value: MediaQuality.labelFor(state.defaultQuality),
            options: [
              MediaQuality.uhd.label,
              MediaQuality.fullHd.label,
              MediaQuality.hd.label,
              MediaQuality.sd.label,
            ],
            labelOf: (q) => q,
            onChanged: (q) => unawaited(notifier.setDefaultQuality(q)),
          ),
          const Divider(height: AppSpacing.xl),
          SettingsSwitchTile(
            icon: Icons.play_arrow_rounded,
            title: 'Start while you watch',
            subtitle:
                'Begin the next download partway through the current episode',
            value: state.downloadOnProgress,
            onChanged: (value) =>
                unawaited(notifier.setDownloadOnProgress(value)),
          ),
          if (state.downloadOnProgress) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                const SettingsIconBox(icon: Icons.percent_rounded),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Start after', style: AppType.bodyStrong()),
                      Text(
                        '$percent% of the episode is watched',
                        style: AppType.caption(),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: Slider(
                    value: state.progressThreshold,
                    min: 0.5,
                    max: 0.95,
                    divisions: 9,
                    label: '$percent%',
                    semanticFormatterCallback: (v) =>
                        '${(v * 100).round()}% watched',
                    onChanged: (value) =>
                        unawaited(notifier.setProgressThreshold(value)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}
