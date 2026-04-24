import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/auto_download_event.dart';
import '../providers/auto_download_events_provider.dart';
import '../providers/auto_download_provider.dart';
import 'common/status_badge.dart';

/// Compact status card shown at top of Calendar when auto-download is enabled
class AutoDownloadStatusCard extends ConsumerWidget {
  const AutoDownloadStatusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autoState = ref.watch(autoDownloadProvider);
    if (!autoState.enabled) return const SizedBox.shrink();

    final recentEvents = ref.watch(recentAutoDownloadEventsProvider);
    final theme = Theme.of(context);
    final trackedCount = autoState.lastDownloadedEpisodes.length;
    final queueCount = autoState.downloadQueue.length;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.sm,
      ),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header row
              Row(
                children: [
                  Icon(
                    Icons.smart_display_rounded,
                    size: AppIconSize.md,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Auto-Download',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (autoState.isProcessing)
                    StatusBadge.info(
                      label: 'Checking',
                      size: StatusBadgeSize.small,
                    )
                  else if (autoState.error != null)
                    StatusBadge.error(
                      label: 'Error',
                      size: StatusBadgeSize.small,
                    )
                  else
                    StatusBadge.success(
                      label: 'Idle',
                      size: StatusBadgeSize.small,
                    ),
                ],
              ),

              const SizedBox(height: AppSpacing.sm),

              // Stats row
              Row(
                children: [
                  _StatChip(
                    icon: Icons.tv_rounded,
                    label: '$trackedCount tracked',
                    theme: theme,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  _StatChip(
                    icon: Icons.queue_rounded,
                    label: '$queueCount in queue',
                    theme: theme,
                  ),
                ],
              ),

              // Recent events
              if (recentEvents.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withAlpha(
                    AppOpacity.medium,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                ...recentEvents
                    .take(3)
                    .map((event) => _EventRow(event: event, theme: theme)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.theme,
  });

  final IconData icon;
  final String label;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.theme});

  final AutoDownloadEvent event;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _iconForType(event.type);
    final timeAgo = _formatTimeAgo(event.timestamp);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              event.message ?? '${event.showName} ${event.episodeCode}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            timeAgo,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.6),
            ),
          ),
        ],
      ),
    );
  }

  (IconData, Color) _iconForType(AutoDownloadEventType type) {
    return switch (type) {
      AutoDownloadEventType.downloadStarted => (
        Icons.download_rounded,
        AppColors.info,
      ),
      AutoDownloadEventType.downloadCompleted => (
        Icons.check_circle_rounded,
        AppColors.success,
      ),
      AutoDownloadEventType.downloadFailed => (
        Icons.error_rounded,
        AppColors.error,
      ),
      AutoDownloadEventType.torrentNotFound => (
        Icons.search_off_rounded,
        AppColors.warning,
      ),
      AutoDownloadEventType.episodeQueued => (
        Icons.queue_rounded,
        AppColors.info,
      ),
      AutoDownloadEventType.checked => (Icons.refresh_rounded, AppColors.info),
    };
  }

  String _formatTimeAgo(DateTime timestamp) {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
