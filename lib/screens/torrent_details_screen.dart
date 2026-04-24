import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/torrent.dart';
import '../providers/torrent_provider.dart';
import '../utils/formatters.dart';
import '../widgets/common/app_progress_bar.dart';
import '../widgets/common/delete_confirmation_dialog.dart';
import '../widgets/common/status_badge.dart';
import '../widgets/torrent_files_tab.dart';
import '../widgets/torrent_info_tab.dart';
import '../widgets/torrent_peers_tab.dart';
import '../widgets/torrent_trackers_tab.dart';

/// Screen showing detailed information about a torrent
class TorrentDetailsScreen extends ConsumerWidget {
  final String torrentHash;

  /// If true, renders without Scaffold for embedding in master-detail layouts
  final bool embedded;

  const TorrentDetailsScreen({
    super.key,
    required this.torrentHash,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final torrent = ref.watch(selectedTorrentProvider);

    if (torrent == null) {
      if (embedded) {
        return const Center(child: Text('Torrent not found'));
      }
      return Scaffold(
        appBar: AppBar(title: const Text('Torrent Details')),
        body: const Center(child: Text('Torrent not found')),
      );
    }

    final content = Column(
      children: [
        // Header card with main info
        _TorrentHeaderCard(torrent: torrent, compact: embedded),

        // Tabs
        Expanded(
          child: DefaultTabController(
            length: 4,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(
                      text: 'Files',
                      icon: Icon(
                        Icons.folder_outlined,
                        size: embedded ? 18 : null,
                      ),
                    ),
                    Tab(
                      text: 'Peers',
                      icon: Icon(
                        Icons.people_outline,
                        size: embedded ? 18 : null,
                      ),
                    ),
                    Tab(
                      text: 'Trackers',
                      icon: Icon(
                        Icons.dns_outlined,
                        size: embedded ? 18 : null,
                      ),
                    ),
                    Tab(
                      text: 'Info',
                      icon: Icon(
                        Icons.info_outline,
                        size: embedded ? 18 : null,
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      TorrentFilesTab(torrentHash: torrentHash),
                      TorrentPeersTab(torrentHash: torrentHash),
                      TorrentTrackersTab(torrentHash: torrentHash),
                      TorrentInfoTab(torrent: torrent),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Action bar at bottom (for embedded mode)
        if (embedded)
          _TorrentActionBar(
            torrent: torrent,
            compact: true,
            onPause: () => ref
                .read(torrentListProvider.notifier)
                .pauseTorrent(torrentHash),
            onResume: () => ref
                .read(torrentListProvider.notifier)
                .resumeTorrent(torrentHash),
            onRecheck: () => ref
                .read(torrentListProvider.notifier)
                .recheckTorrent(torrentHash),
            onReannounce: () => ref
                .read(torrentListProvider.notifier)
                .reannounceTorrent(torrentHash),
            onDelete: () => _showDeleteDialog(context, ref, torrent),
          ),
      ],
    );

    if (embedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(torrent.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(torrentFilesProvider(torrentHash));
              ref.invalidate(torrentPeersProvider(torrentHash));
              ref.invalidate(torrentTrackersProvider(torrentHash));
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: content,
      bottomNavigationBar: _TorrentActionBar(
        torrent: torrent,
        onPause: () =>
            ref.read(torrentListProvider.notifier).pauseTorrent(torrentHash),
        onResume: () =>
            ref.read(torrentListProvider.notifier).resumeTorrent(torrentHash),
        onRecheck: () =>
            ref.read(torrentListProvider.notifier).recheckTorrent(torrentHash),
        onReannounce: () => ref
            .read(torrentListProvider.notifier)
            .reannounceTorrent(torrentHash),
        onDelete: () => _showDeleteDialog(context, ref, torrent),
      ),
    );
  }

  Future<void> _showDeleteDialog(
    BuildContext context,
    WidgetRef ref,
    Torrent torrent,
  ) async {
    final result = await DeleteConfirmationDialog.showForTorrent(
      context: context,
      torrentName: torrent.name,
    );

    if (result != null && result.confirmed) {
      final success = await ref
          .read(torrentListProvider.notifier)
          .deleteTorrent(torrent.hash, deleteFiles: result.deleteFiles);

      if (success && context.mounted) {
        Navigator.of(context).pop();
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete torrent')),
        );
      }
    }
  }
}

class _TorrentHeaderCard extends StatelessWidget {
  final Torrent torrent;
  final bool compact;

  const _TorrentHeaderCard({required this.torrent, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    Color progressColor;
    if (torrent.hasError) {
      progressColor = appColors.errorState;
    } else if (torrent.isPaused) {
      progressColor = appColors.paused;
    } else if (torrent.isCompleted) {
      progressColor = appColors.seeding;
    } else {
      progressColor = appColors.downloading;
    }

    if (compact) {
      // Compact embedded layout - modern stat pills with minimal height
      return Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusBadge.torrent(
                  status: torrent.state,
                  label: torrent.statusText,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    torrent.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  Formatters.formatProgress(torrent.progress),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: progressColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            AppProgressBar.download(
              progress: torrent.progress,
              isError: torrent.hasError,
              isPaused: torrent.isPaused,
              isCompleted: torrent.isCompleted,
              showLabel: false,
              height: 5.0,
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                _StatPill(
                  icon: Icons.download_rounded,
                  label: 'DL',
                  value: Formatters.formatSpeed(torrent.dlspeed),
                  color: appColors.downloading,
                ),
                _StatPill(
                  icon: Icons.upload_rounded,
                  label: 'UL',
                  value: Formatters.formatSpeed(torrent.upspeed),
                  color: appColors.seeding,
                ),
                _StatPill(
                  icon: Icons.timer_rounded,
                  label: 'ETA',
                  value: torrent.eta > 0 && torrent.eta < 8640000
                      ? Formatters.formatDuration(torrent.eta)
                      : '∞',
                  color: appColors.queued,
                ),
                _StatPill(
                  icon: Icons.storage_rounded,
                  label: 'Size',
                  value: Formatters.formatBytes(torrent.size),
                ),
                _StatPill(
                  icon: Icons.people_alt_rounded,
                  label: 'Peers',
                  value: '${torrent.numSeeds}/${torrent.numLeeches}',
                ),
                _StatPill(
                  icon: Icons.swap_vert_rounded,
                  label: 'Ratio',
                  value: Formatters.formatRatio(torrent.ratio),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // Full layout for standalone screen
    final padding = AppSpacing.lg;

    return Card(
      margin: EdgeInsets.all(padding),
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status badge
            Row(
              children: [
                StatusBadge.torrent(
                  status: torrent.state,
                  label: torrent.statusText,
                ),
                const Spacer(),
                Text(
                  Formatters.formatProgress(torrent.progress),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: progressColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Progress bar
            AppProgressBar.download(
              progress: torrent.progress,
              isError: torrent.hasError,
              isPaused: torrent.isPaused,
              isCompleted: torrent.isCompleted,
              showLabel: false,
              height: 8.0,
            ),
            const SizedBox(height: AppSpacing.lg),

            // Stats grid
            Row(
              children: [
                Expanded(
                  child: _StatItem(
                    icon: Icons.download_outlined,
                    label: 'Download',
                    value: Formatters.formatSpeed(torrent.dlspeed),
                    color: appColors.downloading,
                  ),
                ),
                Expanded(
                  child: _StatItem(
                    icon: Icons.upload_outlined,
                    label: 'Upload',
                    value: Formatters.formatSpeed(torrent.upspeed),
                    color: appColors.seeding,
                  ),
                ),
                Expanded(
                  child: _StatItem(
                    icon: Icons.timer_outlined,
                    label: 'ETA',
                    value: torrent.eta > 0 && torrent.eta < 8640000
                        ? Formatters.formatDuration(torrent.eta)
                        : '∞',
                    color: appColors.queued,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _StatItem(
                    icon: Icons.storage_outlined,
                    label: 'Size',
                    value:
                        '${Formatters.formatBytes(torrent.downloaded)} / ${Formatters.formatBytes(torrent.size)}',
                  ),
                ),
                Expanded(
                  child: _StatItem(
                    icon: Icons.people_outline,
                    label: 'Peers',
                    value:
                        '${torrent.numSeeds} seeds, ${torrent.numLeeches} peers',
                  ),
                ),
                Expanded(
                  child: _StatItem(
                    icon: Icons.swap_vert,
                    label: 'Ratio',
                    value: Formatters.formatRatio(torrent.ratio),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  const _StatPill({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color ?? theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label ',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: appColors.mutedText,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Column(
      children: [
        Icon(
          icon,
          size: AppIconSize.md,
          color: color ?? theme.colorScheme.primary,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: appColors.mutedText,
          ),
        ),
        const SizedBox(height: AppSpacing.xs / 2),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: color,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _TorrentActionBar extends StatelessWidget {
  final Torrent torrent;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRecheck;
  final VoidCallback onReannounce;
  final VoidCallback onDelete;
  final bool compact;

  const _TorrentActionBar({
    required this.torrent,
    required this.onPause,
    required this.onResume,
    required this.onRecheck,
    required this.onReannounce,
    required this.onDelete,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;

    final actions = Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        if (torrent.isPaused)
          _ActionButton(
            icon: Icons.play_arrow,
            label: 'Resume',
            onPressed: onResume,
            color: appColors.seeding,
            compact: compact,
          )
        else
          _ActionButton(
            icon: Icons.pause,
            label: 'Pause',
            onPressed: onPause,
            color: appColors.queued,
            compact: compact,
          ),
        _ActionButton(
          icon: Icons.refresh,
          label: 'Recheck',
          onPressed: onRecheck,
          compact: compact,
        ),
        _ActionButton(
          icon: Icons.campaign_outlined,
          label: 'Reannounce',
          onPressed: onReannounce,
          compact: compact,
        ),
        _ActionButton(
          icon: Icons.delete_outline,
          label: 'Delete',
          onPressed: onDelete,
          color: appColors.errorState,
          compact: compact,
        ),
      ],
    );

    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
          ),
        ),
        child: actions,
      );
    }

    return BottomAppBar(child: actions);
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;
  final bool compact;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: compact
          ? TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: compact ? 20 : 24),
          SizedBox(height: compact ? 2 : 4),
          Text(
            label,
            style: TextStyle(fontSize: compact ? 10 : 12, color: color),
          ),
        ],
      ),
    );
  }
}
