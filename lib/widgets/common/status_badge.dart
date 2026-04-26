import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_theme.dart';

/// Types of status badges
enum StatusBadgeType {
  /// Torrent status (downloading, seeding, paused, error, etc.)
  torrent,

  /// Quality indicator (4K, 1080p, 720p, SD)
  quality,

  /// Generic status (success, warning, error, info)
  status,

  /// Custom colors provided directly
  custom,
}

/// Size variants for status badges
enum StatusBadgeSize { small, medium, large }

/// A reusable status badge component with consistent styling
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.type = StatusBadgeType.custom,
    this.size = StatusBadgeSize.medium,
    this.backgroundColor,
    this.textColor,
    this.icon,
  });

  /// Create a badge for torrent status
  factory StatusBadge.torrent({
    Key? key,
    required String status,
    required String label,
    StatusBadgeSize size = StatusBadgeSize.medium,
  }) {
    return StatusBadge(
      key: key,
      label: label,
      type: StatusBadgeType.torrent,
      size: size,
      textColor: status.torrentStateColor,
    );
  }

  /// Create a badge for quality indicator
  factory StatusBadge.quality({
    Key? key,
    required String quality,
    StatusBadgeSize size = StatusBadgeSize.medium,
  }) {
    return StatusBadge(
      key: key,
      label: quality,
      type: StatusBadgeType.quality,
      size: size,
      textColor: quality.qualityColor,
    );
  }

  /// Create a success badge
  factory StatusBadge.success({
    Key? key,
    required String label,
    StatusBadgeSize size = StatusBadgeSize.medium,
  }) {
    return StatusBadge(
      key: key,
      label: label,
      type: StatusBadgeType.status,
      size: size,
      textColor: AppColors.success,
    );
  }

  /// Create a warning badge
  factory StatusBadge.warning({
    Key? key,
    required String label,
    StatusBadgeSize size = StatusBadgeSize.medium,
  }) {
    return StatusBadge(
      key: key,
      label: label,
      type: StatusBadgeType.status,
      size: size,
      textColor: AppColors.warning,
    );
  }

  /// Create an error badge
  factory StatusBadge.error({
    Key? key,
    required String label,
    StatusBadgeSize size = StatusBadgeSize.medium,
  }) {
    return StatusBadge(
      key: key,
      label: label,
      type: StatusBadgeType.status,
      size: size,
      textColor: AppColors.errorState,
    );
  }

  /// Create an info badge
  factory StatusBadge.info({
    Key? key,
    required String label,
    StatusBadgeSize size = StatusBadgeSize.medium,
  }) {
    return StatusBadge(
      key: key,
      label: label,
      type: StatusBadgeType.status,
      size: size,
      textColor: AppColors.info,
    );
  }

  final String label;
  final StatusBadgeType type;
  final StatusBadgeSize size;
  final Color? backgroundColor;
  final Color? textColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    // Determine colors — soft tint will derive from `fgColor` when no
    // explicit background is provided.
    Color fgColor = textColor ?? appColors.paused;

    // Determine sizing
    double horizontalPadding;
    double verticalPadding;
    double fontSize;
    double iconSize;
    double borderRadius;

    // MediaHub pills run small and tight — short rounded rectangles
    // that read as metadata, not buttons.
    switch (size) {
      case StatusBadgeSize.small:
        horizontalPadding = 7;
        verticalPadding = 2;
        fontSize = 10;
        iconSize = AppIconSize.xxs;
        borderRadius = AppRadius.xs;
        break;
      case StatusBadgeSize.medium:
        horizontalPadding = 10;
        verticalPadding = 4;
        fontSize = 11;
        iconSize = AppIconSize.xs;
        borderRadius = AppRadius.xs;
        break;
      case StatusBadgeSize.large:
        horizontalPadding = AppSpacing.md;
        verticalPadding = 6;
        fontSize = 13;
        iconSize = AppIconSize.sm;
        borderRadius = AppRadius.sm;
        break;
    }

    // MediaHub pill styling — soft tint background derived from the
    // foreground colour so a single token drives both. Uppercase mono
    // typography with light letter-spacing.
    final pillBg = (backgroundColor != null)
        ? backgroundColor!
        : fgColor.withAlpha(0x22);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: pillBg,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: fgColor),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: fgColor,
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
              letterSpacing: 0.5,
              fontFamily: 'monospace',
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// A badge specifically for torrent states with proper theming
class TorrentStatusBadge extends StatelessWidget {
  const TorrentStatusBadge({
    super.key,
    required this.isDownloading,
    required this.isSeeding,
    required this.isPaused,
    required this.hasError,
    required this.statusText,
    this.size = StatusBadgeSize.medium,
  });

  final bool isDownloading;
  final bool isSeeding;
  final bool isPaused;
  final bool hasError;
  final String statusText;
  final StatusBadgeSize size;

  @override
  Widget build(BuildContext context) {
    final appColors = context.appColors;

    Color textColor;
    if (hasError) {
      textColor = appColors.errorState;
    } else if (isPaused) {
      textColor = appColors.paused;
    } else if (isDownloading) {
      textColor = appColors.downloading;
    } else if (isSeeding) {
      textColor = appColors.seeding;
    } else {
      textColor = appColors.queued;
    }

    return StatusBadge(label: statusText, size: size, textColor: textColor);
  }
}
