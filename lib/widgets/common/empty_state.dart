import 'package:flutter/material.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Types of empty states for different contexts
enum EmptyStateType {
  /// No data available
  noData,

  /// Search returned no results
  noResults,

  /// Error occurred
  error,
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
    this.compact = false,
  });

  static const double _iconSize = 72.0;

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
    String? secondaryLabel,
    VoidCallback? onSecondary,
  }) {
    final retry = onRetry == null
        ? null
        : FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
          );
    // A second way out — "Open Settings" for a rejected token, "Back" on a
    // pushed page — so an error is never a dead end.
    final secondary = onSecondary == null
        ? null
        : OutlinedButton(
            onPressed: onSecondary,
            child: Text(secondaryLabel ?? 'Back'),
          );
    return EmptyState(
      key: key,
      icon: Icons.error_outline_rounded,
      title: title ?? 'Something went wrong',
      subtitle: helpText != null ? '$message\n\n$helpText' : message,
      type: EmptyStateType.error,
      action: retry != null && secondary != null
          ? Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              alignment: WrapAlignment.center,
              children: [retry, secondary],
            )
          : retry ?? secondary,
    );
  }

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final EmptyStateType type;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final colorScheme = theme.colorScheme;

    final isError = type == EmptyStateType.error;
    final iconColor = isError ? appColors.errorState : appColors.mutedText;
    final bgColor = isError
        ? appColors.errorStateBackground
        : colorScheme.surfaceContainerHigh;

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
              child: Icon(icon, size: _iconSize * 0.4, color: iconColor),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: AppType.bodyStrong()),
                  if (subtitle != null) ...[
                    const SizedBox(height: AppSpacing.xxs),
                    Text(
                      subtitle!,
                      style: AppType.caption(color: appColors.mutedText),
                    ),
                  ],
                ],
              ),
            ),
            ?action,
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
                    width: _iconSize * 1.6,
                    height: _iconSize * 1.6,
                    decoration: BoxDecoration(
                      color: bgColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: _iconSize, color: iconColor),
                  ),
                );
              },
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text(title, style: AppType.title(), textAlign: TextAlign.center),
            if (subtitle != null) ...[
              const SizedBox(height: AppSpacing.sm),
              ConstrainedBox(
                // A long explanation reads as a paragraph, not a banner
                // spanning a wide window.
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(
                  subtitle!,
                  style: AppType.body(color: appColors.mutedText),
                  textAlign: TextAlign.center,
                ),
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
