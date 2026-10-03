import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/tracker.dart';
import '../providers/torrent_provider.dart';
import 'common/empty_state.dart';
import 'common/loading_state.dart';

/// Label, icon and colour for a qBittorrent tracker status code.
///
/// 0–4 are the long-standing codes; newer qBittorrent versions add 5
/// (tracker error) and 6 (unreachable), which used to fall through to a grey
/// "Disabled" icon with an "Unknown" label. And every status chip carried a
/// check mark, so a broken tracker read "✓ Not working". Each status now has
/// its own icon, used on both the row and the chip.
({String label, IconData icon, Color tone}) trackerStatusStyle(int status) =>
    switch (status) {
      0 => (label: 'Disabled', icon: Icons.block_rounded, tone: AppColors.fg2),
      1 => (
        label: 'Not contacted yet',
        icon: Icons.schedule_rounded,
        tone: AppColors.warn,
      ),
      2 => (
        label: 'Working',
        icon: Icons.check_circle_outline_rounded,
        tone: AppColors.ok,
      ),
      3 => (
        label: 'Updating',
        icon: Icons.sync_rounded,
        tone: AppColors.accent,
      ),
      4 => (
        label: 'Not working',
        icon: Icons.error_outline_rounded,
        tone: AppColors.err,
      ),
      5 => (
        label: 'Tracker error',
        icon: Icons.report_outlined,
        tone: AppColors.err,
      ),
      6 => (
        label: 'Unreachable',
        icon: Icons.cloud_off_rounded,
        tone: AppColors.err,
      ),
      _ => (
        label: 'Unknown',
        icon: Icons.help_outline_rounded,
        tone: AppColors.fg2,
      ),
    };

/// A torrent's trackers and how each is doing.
class TorrentTrackersTab extends ConsumerWidget {
  const TorrentTrackersTab({super.key, required this.torrentHash});

  final String torrentHash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackersAsync = ref.watch(torrentTrackersProvider(torrentHash));

    return trackersAsync.when(
      data: (trackers) => trackers.isEmpty
          ? EmptyState.noData(icon: Icons.dns_outlined, title: 'No trackers')
          : ListView.builder(
              itemCount: trackers.length,
              itemBuilder: (context, index) =>
                  _TrackerRow(tracker: trackers[index]),
            ),
      loading: () => const LoadingIndicator(message: 'Loading trackers…'),
      error: (_, _) => EmptyState.error(
        title: "Couldn't load the trackers",
        message: "The torrent engine didn't answer.",
        onRetry: () => ref.invalidate(torrentTrackersProvider(torrentHash)),
      ),
    );
  }
}

class _TrackerRow extends StatelessWidget {
  const _TrackerRow({required this.tracker});

  final Tracker tracker;

  @override
  Widget build(BuildContext context) {
    final status = trackerStatusStyle(tracker.status);
    final counts = [
      // qBittorrent reports -1 where a tracker has not said.
      if (tracker.numSeeds >= 0)
        '${tracker.numSeeds} ${tracker.numSeeds == 1 ? 'seed' : 'seeds'}',
      if (tracker.numLeeches >= 0)
        '${tracker.numLeeches} ${tracker.numLeeches == 1 ? 'peer' : 'peers'}',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(status.icon, size: AppIconSize.md, color: status.tone),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  tracker.url,
                  maxLines: 1,
                  style: AppType.mono(
                    size: AppType.sizeCaption,
                    color: AppColors.fg,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _StatusChip(
                      label: status.label,
                      icon: status.icon,
                      tone: status.tone,
                    ),
                    if (counts.isNotEmpty)
                      Text(
                        counts,
                        style: AppType.mono(
                          size: AppType.sizeSmall,
                          color: AppColors.fg1,
                        ),
                      ),
                  ],
                ),
                if (tracker.msg.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    tracker.msg,
                    style: AppType.caption(color: AppColors.fg2),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.icon,
    required this.tone,
  });

  final String label;
  final IconData icon;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: tone.withAlpha(AppOpacity.subtle),
        borderRadius: BorderRadius.circular(AppRadius.xxs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: tone),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: AppType.ui(
              size: AppType.sizeSmall,
              color: tone,
              weight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
