import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_theme.dart';

/// Types of progress bars for different contexts
enum ProgressBarType {
  /// Download progress - uses state-based colors (downloading/paused/error/completed)
  download,

  /// Upload progress - green color
  upload,

  /// Watch progress - primary color with subtle background
  watch,

  /// Generic progress - uses primary color
  generic,
}

/// A reusable progress bar component with consistent styling
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.progress,
    this.type = ProgressBarType.generic,
    this.height = 6.0,
    this.showLabel = false,
    this.labelPosition = ProgressLabelPosition.end,
    this.color,
    this.backgroundColor,
    this.isError = false,
    this.isPaused = false,
    this.isCompleted = false,
    this.animated = true,
    this.borderRadius,
  });

  /// Create a download progress bar that changes color based on state
  factory AppProgressBar.download({
    Key? key,
    required double progress,
    bool isError = false,
    bool isPaused = false,
    bool isCompleted = false,
    bool showLabel = true,
    double height = 6.0,
  }) {
    return AppProgressBar(
      key: key,
      progress: progress,
      type: ProgressBarType.download,
      isError: isError,
      isPaused: isPaused,
      isCompleted: isCompleted,
      showLabel: showLabel,
      height: height,
    );
  }

  /// Create an upload progress bar
  factory AppProgressBar.upload({
    Key? key,
    required double progress,
    bool showLabel = false,
    double height = 6.0,
  }) {
    return AppProgressBar(
      key: key,
      progress: progress,
      type: ProgressBarType.upload,
      showLabel: showLabel,
      height: height,
      color: AppColors.seeding,
    );
  }

  /// Create a watch progress bar (for video playback)
  factory AppProgressBar.watch({
    Key? key,
    required double progress,
    double height = 4.0,
  }) {
    return AppProgressBar(
      key: key,
      progress: progress,
      type: ProgressBarType.watch,
      height: height,
      showLabel: false,
    );
  }

  final double progress;
  final ProgressBarType type;
  final double height;
  final bool showLabel;
  final ProgressLabelPosition labelPosition;
  final Color? color;
  final Color? backgroundColor;
  final bool isError;
  final bool isPaused;
  final bool isCompleted;
  final bool animated;
  final double? borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    // Determine the progress color based on type and state
    Color progressColor;
    if (color != null) {
      progressColor = color!;
    } else {
      switch (type) {
        case ProgressBarType.download:
          if (isError) {
            progressColor = appColors.errorState;
          } else if (isPaused) {
            progressColor = appColors.paused;
          } else if (isCompleted) {
            progressColor = appColors.seeding;
          } else {
            progressColor = theme.colorScheme.primary;
          }
          break;
        case ProgressBarType.upload:
          progressColor = appColors.seeding;
          break;
        case ProgressBarType.watch:
          progressColor = theme.colorScheme.primary;
          break;
        case ProgressBarType.generic:
          progressColor = theme.colorScheme.primary;
          break;
      }
    }

    // Background color
    final bgColor = backgroundColor ?? progressColor.withAlpha(AppOpacity.light);

    // Border radius
    final radius = borderRadius ?? AppRadius.xs;

    // Build the progress indicator with modern styling
    Widget progressBar = Container(
      height: height,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: animated
          ? TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
              duration: AppDuration.normal,
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: value,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          progressColor,
                          progressColor.withAlpha(AppOpacity.heavy),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(radius),
                      boxShadow: value > 0.01 ? [
                        BoxShadow(
                          color: progressColor.withAlpha(AppOpacity.medium),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ] : null,
                    ),
                  ),
                );
              },
            )
          : FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: progress.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      progressColor,
                      progressColor.withAlpha(AppOpacity.heavy),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
            ),
    );

    // If no label, return just the progress bar
    if (!showLabel) {
      return progressBar;
    }

    // Build label with modern styling
    final label = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xxs),
      decoration: BoxDecoration(
        color: progressColor.withAlpha(AppOpacity.subtle),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        '${(progress * 100).toStringAsFixed(1)}%',
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: progressColor,
          letterSpacing: 0.2,
        ),
      ),
    );

    // Return with label
    if (labelPosition == ProgressLabelPosition.end) {
      return Row(
        children: [
          Expanded(child: progressBar),
          SizedBox(width: AppSpacing.md),
          label,
        ],
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          SizedBox(height: AppSpacing.xs),
          progressBar,
        ],
      );
    }
  }
}

/// Position of the progress label
enum ProgressLabelPosition {
  /// Label at the end of the progress bar (right side)
  end,

  /// Label above the progress bar
  top,
}

/// A circular progress indicator with percentage display
class CircularProgressWithLabel extends StatelessWidget {
  const CircularProgressWithLabel({
    super.key,
    required this.progress,
    this.size = 48.0,
    this.strokeWidth = 4.0,
    this.color,
    this.backgroundColor,
    this.showLabel = true,
    this.labelStyle,
  });

  final double progress;
  final double size;
  final double strokeWidth;
  final Color? color;
  final Color? backgroundColor;
  final bool showLabel;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progressColor = color ?? theme.colorScheme.primary;
    final bgColor = backgroundColor ?? progressColor.withAlpha(AppOpacity.light);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            strokeWidth: strokeWidth,
            backgroundColor: bgColor,
            valueColor: AlwaysStoppedAnimation(progressColor),
          ),
          if (showLabel)
            Text(
              '${(progress * 100).toInt()}%',
              style: labelStyle ??
                  theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: size * 0.22,
                  ),
            ),
        ],
      ),
    );
  }
}
