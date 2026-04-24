import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_theme.dart';

/// Types of empty states for different contexts
enum EmptyStateType {
  /// No data available
  noData,

  /// Search returned no results
  noResults,

  /// Error occurred
  error,

  /// No network connection
  offline,

  /// Custom type with user-provided content
  custom,
}

/// A modern empty state component with consistent styling
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.type = EmptyStateType.noData,
    this.iconSize = 72.0,
    this.compact = false,
  });

  /// Create an empty state for no data
  factory EmptyState.noData({
    Key? key,
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? action,
  }) {
    return EmptyState(
      key: key,
      icon: icon,
      title: title,
      subtitle: subtitle,
      action: action,
      type: EmptyStateType.noData,
    );
  }

  /// Create an empty state for no search results
  factory EmptyState.noResults({
    Key? key,
    String title = 'No results found',
    String? subtitle,
    Widget? action,
  }) {
    return EmptyState(
      key: key,
      icon: Icons.search_off_rounded,
      title: title,
      subtitle: subtitle,
      action: action,
      type: EmptyStateType.noResults,
    );
  }

  /// Create an empty state for errors with detailed context
  factory EmptyState.error({
    Key? key,
    required String message,
    String? title,
    String? helpText,
    VoidCallback? onRetry,
  }) {
    return EmptyState(
      key: key,
      icon: Icons.error_outline_rounded,
      title: title ?? 'Something went wrong',
      subtitle: helpText != null ? '$message\n\n$helpText' : message,
      type: EmptyStateType.error,
      action: onRetry != null
          ? FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try Again'),
            )
          : null,
    );
  }

  /// Create an empty state for connection errors with troubleshooting help
  factory EmptyState.connectionError({
    Key? key,
    String? errorMessage,
    VoidCallback? onRetry,
    VoidCallback? onOpenSettings,
  }) {
    return EmptyState(
      key: key,
      icon: Icons.link_off_rounded,
      title: 'Connection Failed',
      subtitle: errorMessage ?? 'Could not connect to qBittorrent.',
      type: EmptyStateType.error,
      action: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (onOpenSettings != null)
            OutlinedButton.icon(
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings_rounded, size: 18),
              label: const Text('Settings'),
            ),
          if (onOpenSettings != null && onRetry != null)
            const SizedBox(width: 12),
          if (onRetry != null)
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  /// Create an empty state for offline/no connection
  factory EmptyState.offline({Key? key, VoidCallback? onRetry}) {
    return EmptyState(
      key: key,
      icon: Icons.cloud_off_rounded,
      title: 'No connection',
      subtitle: 'Please check your internet connection',
      type: EmptyStateType.offline,
      action: onRetry != null
          ? FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try Again'),
            )
          : null,
    );
  }

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final EmptyStateType type;
  final double iconSize;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final colorScheme = theme.colorScheme;

    // Determine colors based on type
    Color iconColor;
    Color bgColor;
    List<Color>? gradientColors;

    switch (type) {
      case EmptyStateType.error:
        iconColor = appColors.errorState;
        bgColor = appColors.errorStateBackground;
        gradientColors = AppColors.gradientError;
        break;
      case EmptyStateType.offline:
        iconColor = appColors.warning;
        bgColor = appColors.warningBackground;
        gradientColors = AppColors.gradientWarning;
        break;
      default:
        iconColor = appColors.mutedText;
        bgColor = colorScheme.surfaceContainerHigh;
        gradientColors = null;
    }

    if (compact) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icon, size: iconSize * 0.4, color: iconColor),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: appColors.mutedText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (action != null) action!,
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Animated icon with background
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: AppDuration.slow,
              curve: Curves.easeOutBack,
              builder: (context, value, child) {
                return Transform.scale(
                  scale: value,
                  child: Container(
                    width: iconSize * 1.6,
                    height: iconSize * 1.6,
                    decoration: BoxDecoration(
                      gradient: gradientColors != null
                          ? LinearGradient(
                              colors: gradientColors
                                  .map((c) => c.withAlpha(AppOpacity.light))
                                  .toList(),
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : null,
                      color: gradientColors == null ? bgColor : null,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: iconSize, color: iconColor),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                subtitle!,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: appColors.mutedText,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xxl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// A modern loading state widget with consistent styling
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.message, this.compact = false});

  final String? message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    if (compact) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
              ),
            ),
            if (message != null) ...[
              const SizedBox(width: AppSpacing.lg),
              Text(
                message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: appColors.subtleText,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.xl),
            Text(
              message!,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: appColors.subtleText,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
