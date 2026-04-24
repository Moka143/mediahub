import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/tracker.dart';
import '../providers/torrent_provider.dart';
import 'common/empty_state.dart';
import 'common/loading_state.dart';

/// Tab widget for displaying torrent trackers
class TorrentTrackersTab extends ConsumerWidget {
  final String torrentHash;

  const TorrentTrackersTab({super.key, required this.torrentHash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trackersAsync = ref.watch(torrentTrackersProvider(torrentHash));

    return trackersAsync.when(
      data: (trackers) => _buildTrackersList(context, ref, trackers),
      loading: () => const LoadingIndicator(message: 'Loading trackers...'),
      error: (error, stack) => EmptyState.error(
        message: error.toString(),
        onRetry: () => ref.invalidate(torrentTrackersProvider(torrentHash)),
      ),
    );
  }

  Widget _buildTrackersList(BuildContext context, WidgetRef ref, List<Tracker> trackers) {
    if (trackers.isEmpty) {
      return EmptyState.noData(
        icon: Icons.dns_outlined,
        title: 'No trackers',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.sm),
      itemCount: trackers.length,
      itemBuilder: (context, index) {
        final tracker = trackers[index];
        return _TrackerListItem(tracker: tracker);
      },
    );
  }
}

class _TrackerListItem extends StatelessWidget {
  final Tracker tracker;

  const _TrackerListItem({required this.tracker});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    Color statusColor;
    IconData statusIcon;

    switch (tracker.status) {
      case 2: // Working
        statusColor = appColors.success;
        statusIcon = Icons.check_circle_outline;
        break;
      case 3: // Updating
        statusColor = appColors.downloading;
        statusIcon = Icons.sync;
        break;
      case 4: // Not working
        statusColor = appColors.errorState;
        statusIcon = Icons.error_outline;
        break;
      case 1: // Not contacted
        statusColor = appColors.queued;
        statusIcon = Icons.schedule;
        break;
      default: // Disabled
        statusColor = appColors.paused;
        statusIcon = Icons.block;
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withAlpha(51),
          child: Icon(statusIcon, color: statusColor, size: 20),
        ),
        title: Text(
          tracker.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Row(
          children: [
            _buildStatChip(
              context,
              Icons.check_circle_outline,
              tracker.statusText,
              statusColor,
            ),
            const SizedBox(width: 8),
            if (tracker.numSeeds >= 0)
              _buildStatChip(
                context,
                Icons.upload_outlined,
                '${tracker.numSeeds} seeds',
                Colors.green,
              ),
            const SizedBox(width: 8),
            if (tracker.numLeeches >= 0)
              _buildStatChip(
                context,
                Icons.download_outlined,
                '${tracker.numLeeches} peers',
                Colors.blue,
              ),
          ],
        ),
        trailing: tracker.msg.isNotEmpty
            ? Tooltip(
                message: tracker.msg,
                child: const Icon(Icons.info_outline, size: 18),
              )
            : null,
      ),
    );
  }

  Widget _buildStatChip(BuildContext context, IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
