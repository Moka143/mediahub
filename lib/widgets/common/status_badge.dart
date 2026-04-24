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
      backgroundColor: status.torrentStateLightColor,
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
      backgroundColor: quality.qualityLightColor,
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
      backgroundColor: AppColors.successLight,
      textColor: AppColors.successDark,
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
      backgroundColor: AppColors.warningLight,
      textColor: AppColors.warningDark,
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
      backgroundColor: AppColors.errorLight,
      textColor: AppColors.errorDark,
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
      backgroundColor: AppColors.infoLight,
      textColor: AppColors.infoDark,
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

    // Determine colors
    Color bgColor = backgroundColor ?? appColors.pausedBackground;
    Color fgColor = textColor ?? appColors.paused;

    // Determine sizing
    double horizontalPadding;
    double verticalPadding;
    double fontSize;
    double iconSize;
    double borderRadius;

    switch (size) {
      case StatusBadgeSize.small:
        horizontalPadding = AppSpacing.sm;
        verticalPadding = AppSpacing.xs / 2;
        fontSize = 10;
        iconSize = AppIconSize.xs;
        borderRadius = AppRadius.xs;
        break;
      case StatusBadgeSize.medium:
        horizontalPadding = AppSpacing.sm;
        verticalPadding = AppSpacing.xs;
        fontSize = 12;
        iconSize = AppIconSize.xs;
        borderRadius = AppRadius.md;
        break;
      case StatusBadgeSize.large:
        horizontalPadding = AppSpacing.md;
        verticalPadding = AppSpacing.sm;
        fontSize = 14;
        iconSize = AppIconSize.sm;
        borderRadius = AppRadius.md;
        break;
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: fgColor.withAlpha(AppOpacity.light),
          width: AppBorderWidth.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: iconSize, color: fgColor),
            SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fgColor,
              fontWeight: FontWeight.w600,
              fontSize: fontSize,
              letterSpacing: 0.2,
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

    Color backgroundColor;
    Color textColor;

    if (hasError) {
      backgroundColor = appColors.errorStateBackground;
      textColor = appColors.errorState;
    } else if (isPaused) {
      backgroundColor = appColors.pausedBackground;
      textColor = appColors.paused;
    } else if (isDownloading) {
      backgroundColor = appColors.downloadingBackground;
      textColor = appColors.downloading;
    } else if (isSeeding) {
      backgroundColor = appColors.seedingBackground;
      textColor = appColors.seeding;
    } else {
      backgroundColor = appColors.queuedBackground;
      textColor = appColors.queued;
    }

    return StatusBadge(
      label: statusText,
      size: size,
      backgroundColor: backgroundColor,
      textColor: textColor,
    );
  }
}
