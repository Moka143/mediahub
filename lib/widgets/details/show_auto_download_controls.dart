import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../providers/auto_download_provider.dart';
import '../../services/auto_download_service.dart';
import '../common/mediahub_chip.dart';
import 'show_detail_sections.dart';

/// Qualities offered for a show's automatic downloads.
const List<String> autoDownloadQualities = ['2160p', '1080p', '720p'];

/// One line on where a show's automatic downloads stand — "S02E04
/// downloading" — for the show page and its Favorites card.
String autoDownloadStatusLabel(EpisodeTrackingInfo tracking) {
  final code = tracking.episodeCode;
  return switch (tracking.status) {
    EpisodeDownloadStatus.notAired => "$code hasn't aired yet",
    EpisodeDownloadStatus.awaitingTorrent => '$code: waiting for a source',
    EpisodeDownloadStatus.available => '$code: ready to download',
    EpisodeDownloadStatus.downloading => '$code downloading',
    EpisodeDownloadStatus.downloaded => '$code downloaded',
    EpisodeDownloadStatus.watched => '$code watched',
  };
}

/// Per-show automatic download settings on the show page: on/off and the
/// quality to fetch.
///
/// The README promised a per-show quality preference and a per-show
/// switch; the provider had both (`setShowQualityPreference`,
/// `setShowAutoDownloadOverride`) and nothing in the app called either —
/// the only control was an Auto/On/Off pill inside the player.
class ShowAutoDownloadControls extends ConsumerWidget {
  const ShowAutoDownloadControls({super.key, required this.showId});

  final int showId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(
      autoDownloadProvider.select(
        (s) => (
          global: s.enabled,
          override: s.showAutoDownloadOverrides[showId],
          quality: s.showQualityPreferences[showId],
          defaultQuality: s.defaultQuality,
        ),
      ),
    );
    final tracking = ref.watch(showAutoDownloadTrackingProvider(showId));
    final notifier = ref.read(autoDownloadProvider.notifier);

    final quality = settings.quality ?? settings.defaultQuality;
    final appSetting = settings.global ? 'On' : 'Off';

    return InfoSection(
      title: 'Auto-download',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Downloads the next episode once you've watched the one before "
            '— new episodes too, as they air.',
            style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg1),
          ),
          const SizedBox(height: AppSpacing.md),
          _ChoiceRow(
            label: 'New episodes',
            children: [
              MediaHubFilterChip(
                label: 'App setting ($appSetting)',
                selected: settings.override == null,
                onTap: () => unawaited(
                  notifier.setShowAutoDownloadOverride(showId, null),
                ),
              ),
              MediaHubFilterChip(
                label: 'On',
                selected: settings.override == true,
                onTap: () => unawaited(
                  notifier.setShowAutoDownloadOverride(showId, true),
                ),
              ),
              MediaHubFilterChip(
                label: 'Off',
                selected: settings.override == false,
                onTap: () => unawaited(
                  notifier.setShowAutoDownloadOverride(showId, false),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _ChoiceRow(
            label: 'Quality',
            children: [
              for (final q in autoDownloadQualities)
                MediaHubFilterChip(
                  label: q == settings.defaultQuality ? '$q (default)' : q,
                  selected: q == quality,
                  onTap: () =>
                      unawaited(notifier.setShowQualityPreference(showId, q)),
                ),
            ],
          ),
          if (tracking != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'Latest: ${autoDownloadStatusLabel(tracking)}',
              style: AppType.mono(
                size: AppType.sizeSmall,
                color: AppColors.fg2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: AppType.ui(size: AppType.sizeCaption, color: AppColors.fg2),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: children,
          ),
        ),
      ],
    );
  }
}
