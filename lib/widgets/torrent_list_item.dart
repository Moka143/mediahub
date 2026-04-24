import 'package:flutter/material.dart';

import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../models/torrent.dart';
import '../utils/formatters.dart';
import 'common/app_progress_bar.dart';
import 'common/status_badge.dart';

/// Modern widget to display a single torrent in a list
class TorrentListItem extends StatefulWidget {
  final Torrent torrent;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onDelete;
  final bool selected;

  const TorrentListItem({
    super.key,
    required this.torrent,
    this.onTap,
    this.onLongPress,
    this.onPause,
    this.onResume,
    this.onDelete,
    this.selected = false,
  });

  @override
  State<TorrentListItem> createState() => _TorrentListItemState();
}

class _TorrentListItemState extends State<TorrentListItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final appColors = context.appColors;
    final isDark = theme.brightness == Brightness.dark;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: AppDuration.fast,
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: widget.selected
              ? colorScheme.primaryContainer.withAlpha(AppOpacity.medium)
              : (_isHovered
                    ? (isDark ? colorScheme.surfaceContainerHigh : Colors.white)
                    : appColors.cardBackground),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: widget.selected
              ? Border.all(
                  color: colorScheme.primary,
                  width: AppBorderWidth.medium,
                )
              : Border.all(
                  color: _isHovered
                      ? colorScheme.outline.withAlpha(AppOpacity.medium)
                      : Colors.transparent,
                  width: AppBorderWidth.thin,
                ),
          boxShadow: [
            if (_isHovered || widget.selected)
              BoxShadow(
                color: (isDark ? Colors.black : colorScheme.shadow).withAlpha(
                  _isHovered ? AppOpacity.light : AppOpacity.subtle,
                ),
                blurRadius: _isHovered ? 16 : 8,
                offset: Offset(0, _isHovered ? 4 : 2),
              ),
          ],
        ),
        child: Semantics(
          label:
              '${widget.torrent.name}. ${widget.torrent.statusText}. ${(widget.torrent.progress * 100).toStringAsFixed(0)} percent complete',
          button: true,
          selected: widget.selected,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title row with status
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Status indicator dot
                        Container(
                          margin: const EdgeInsets.only(
                            top: 6,
                            right: AppSpacing.md,
                          ),
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _getStatusColor(appColors),
                            boxShadow: [
                              BoxShadow(
                                color: _getStatusColor(
                                  appColors,
                                ).withAlpha(AppOpacity.semi),
                                blurRadius: 6,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.torrent.name,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  height: 1.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Row(
                                children: [
                                  TorrentStatusBadge(
                                    isDownloading: widget.torrent.isDownloading,
                                    isSeeding: widget.torrent.isSeeding,
                                    isPaused: widget.torrent.isPaused,
                                    hasError: widget.torrent.hasError,
                                    statusText: widget.torrent.statusText,
                                  ),
                                  if (widget.torrent.isStreamingMode) ...[
                                    const SizedBox(width: AppSpacing.sm),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: AppSpacing.sm,
                                        vertical: AppSpacing.xxs,
                                      ),
                                      decoration: BoxDecoration(
                                        color: colorScheme.tertiary.withAlpha(
                                          AppOpacity.light,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppRadius.sm,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.play_circle_outline_rounded,
                                            size: 12,
                                            color: colorScheme.tertiary,
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            'Streaming',
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color: colorScheme.tertiary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),

                    // Progress bar
                    AppProgressBar.download(
                      progress: widget.torrent.progress,
                      isError: widget.torrent.hasError,
                      isPaused: widget.torrent.isPaused,
                      isCompleted: widget.torrent.isCompleted,
                      showLabel: true,
                    ),
                    const SizedBox(height: AppSpacing.lg),

                    // Stats row
                    _buildStatsRow(context),

                    // Action buttons
                    if (_isHovered || widget.selected) ...[
                      const SizedBox(height: AppSpacing.md),
                      _buildActionButtons(context),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _getStatusColor(AppColorsExtension appColors) {
    if (widget.torrent.hasError) return appColors.errorState;
    if (widget.torrent.isPaused) return appColors.paused;
    if (widget.torrent.isDownloading) return appColors.downloading;
    if (widget.torrent.isSeeding) return appColors.seeding;
    return appColors.queued;
  }

  Widget _buildStatsRow(BuildContext context) {
    final appColors = context.appColors;

    return Wrap(
      spacing: AppSpacing.xl,
      runSpacing: AppSpacing.sm,
      children: [
        // Size
        _buildStatItem(
          context,
          Icons.folder_outlined,
          '${Formatters.formatBytes(widget.torrent.downloaded)} / ${Formatters.formatBytes(widget.torrent.size)}',
          null,
        ),

        // Download speed
        if (widget.torrent.dlspeed > 0)
          _buildStatItem(
            context,
            Icons.arrow_downward_rounded,
            Formatters.formatSpeed(widget.torrent.dlspeed),
            appColors.downloading,
          ),

        // Upload speed
        if (widget.torrent.upspeed > 0)
          _buildStatItem(
            context,
            Icons.arrow_upward_rounded,
            Formatters.formatSpeed(widget.torrent.upspeed),
            appColors.seeding,
          ),

        // ETA
        if (widget.torrent.isDownloading &&
            widget.torrent.eta > 0 &&
            widget.torrent.eta < 8640000)
          _buildStatItem(
            context,
            Icons.schedule_rounded,
            Formatters.formatDuration(widget.torrent.eta),
            null,
          ),

        // Seeds/Peers
        _buildStatItem(
          context,
          Icons.group_outlined,
          '${widget.torrent.numSeeds} / ${widget.torrent.numLeeches}',
          null,
        ),

        // Ratio
        _buildStatItem(
          context,
          Icons.sync_alt_rounded,
          Formatters.formatRatio(widget.torrent.ratio),
          null,
        ),
      ],
    );
  }

  Widget _buildStatItem(
    BuildContext context,
    IconData icon,
    String text,
    Color? accentColor,
  ) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final color = accentColor ?? appColors.subtleText;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: (accentColor ?? theme.colorScheme.outline).withAlpha(
          AppOpacity.subtle,
        ),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppIconSize.sm, color: color),
          const SizedBox(width: AppSpacing.xs),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    final appColors = context.appColors;

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (widget.torrent.isPaused)
          FilledButton.tonalIcon(
            onPressed: widget.onResume,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Resume'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
            ),
          )
        else
          FilledButton.tonalIcon(
            onPressed: widget.onPause,
            icon: const Icon(Icons.pause_rounded, size: 18),
            label: const Text('Pause'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
            ),
          ),
        const SizedBox(width: AppSpacing.sm),
        IconButton.outlined(
          icon: const Icon(Icons.delete_outline_rounded, size: 20),
          tooltip: 'Delete',
          onPressed: widget.onDelete,
          color: appColors.errorState,
          style: IconButton.styleFrom(
            side: BorderSide(
              color: appColors.errorState.withAlpha(AppOpacity.medium),
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact version of torrent list item for dense view
class TorrentListItemCompact extends StatelessWidget {
  final Torrent torrent;
  final VoidCallback? onTap;

  const TorrentListItemCompact({super.key, required this.torrent, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    Color stateColor;
    Color stateBgColor;
    if (torrent.hasError) {
      stateColor = appColors.errorState;
      stateBgColor = appColors.errorStateBackground;
    } else if (torrent.isPaused) {
      stateColor = appColors.paused;
      stateBgColor = appColors.pausedBackground;
    } else if (torrent.isDownloading) {
      stateColor = appColors.downloading;
      stateBgColor = appColors.downloadingBackground;
    } else if (torrent.isSeeding) {
      stateColor = appColors.seeding;
      stateBgColor = appColors.seedingBackground;
    } else {
      stateColor = appColors.queued;
      stateBgColor = appColors.queuedBackground;
    }

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: appColors.cardBackground,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: stateBgColor,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Center(
            child: Text(
              Formatters.formatProgress(torrent.progress).replaceAll('%', ''),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: stateColor,
              ),
            ),
          ),
        ),
        title: Text(
          torrent.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Row(
          children: [
            Expanded(
              child: Text(
                '${Formatters.formatBytes(torrent.size)} • ${torrent.statusText}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: appColors.subtleText,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (torrent.isStreamingMode) ...[
              const SizedBox(width: AppSpacing.xs),
              Icon(
                Icons.play_circle_outline_rounded,
                size: 14,
                color: theme.colorScheme.tertiary,
              ),
            ],
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (torrent.dlspeed > 0)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_downward_rounded,
                    size: 12,
                    color: appColors.downloading,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    Formatters.formatSpeed(torrent.dlspeed),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: appColors.downloading,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            if (torrent.upspeed > 0) ...[
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_upward_rounded,
                    size: 12,
                    color: appColors.seeding,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    Formatters.formatSpeed(torrent.upspeed),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: appColors.seeding,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A swipeable wrapper for TorrentListItem with quick actions
class SwipeableTorrentListItem extends StatelessWidget {
  final Torrent torrent;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onDelete;
  final bool selected;
  final bool enableSwipe;

  const SwipeableTorrentListItem({
    super.key,
    required this.torrent,
    this.onTap,
    this.onLongPress,
    this.onPause,
    this.onResume,
    this.onDelete,
    this.selected = false,
    this.enableSwipe = true,
  });

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;

    if (!enableSwipe) {
      return TorrentListItem(
        torrent: torrent,
        onTap: onTap,
        onLongPress: onLongPress,
        onPause: onPause,
        onResume: onResume,
        onDelete: onDelete,
        selected: selected,
      );
    }

    return Dismissible(
      key: Key(torrent.hash),
      direction: DismissDirection.horizontal,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // Swipe left -> Delete (show confirmation)
          return false; // Don't actually dismiss, just trigger action
        } else {
          // Swipe right -> Toggle pause/resume
          if (torrent.isPaused) {
            onResume?.call();
          } else {
            onPause?.call();
          }
          return false; // Don't dismiss
        }
      },
      onUpdate: (details) {
        // Trigger haptic feedback at threshold
        if (details.reached && details.previousReached != details.reached) {
          // Could add haptic feedback here if desired
        }
      },
      background: _buildSwipeBackground(
        context,
        isLeft: true,
        color: torrent.isPaused ? appColors.success : appColors.warning,
        icon: torrent.isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
        label: torrent.isPaused ? 'Resume' : 'Pause',
      ),
      secondaryBackground: _buildSwipeBackground(
        context,
        isLeft: false,
        color: appColors.errorState,
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        onTap: onDelete,
      ),
      child: TorrentListItem(
        torrent: torrent,
        onTap: onTap,
        onLongPress: onLongPress,
        onPause: onPause,
        onResume: onResume,
        onDelete: onDelete,
        selected: selected,
      ),
    );
  }

  Widget _buildSwipeBackground(
    BuildContext context, {
    required bool isLeft,
    required Color color,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: color.withAlpha(AppOpacity.medium),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isLeft) ...[
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            if (isLeft) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
