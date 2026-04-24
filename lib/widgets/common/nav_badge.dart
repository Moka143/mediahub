import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';

/// A badge overlay for navigation icons showing counts
class NavBadge extends StatelessWidget {
  const NavBadge({
    super.key,
    required this.child,
    required this.count,
    this.showZero = false,
    this.maxCount = 99,
    this.backgroundColor,
    this.textColor,
    this.isError = false,
  });

  /// The icon widget to wrap
  final Widget child;

  /// The count to display
  final int count;

  /// Whether to show the badge when count is zero
  final bool showZero;

  /// Maximum count to display (shows "99+" if exceeded)
  final int maxCount;

  /// Background color of the badge
  final Color? backgroundColor;

  /// Text color of the badge
  final Color? textColor;

  /// Whether this is an error indicator (uses error color)
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shouldShow = showZero || count > 0;

    if (!shouldShow) {
      return child;
    }

    final bgColor = backgroundColor ??
        (isError ? theme.colorScheme.error : theme.colorScheme.primary);
    final fgColor = textColor ??
        (isError ? theme.colorScheme.onError : theme.colorScheme.onPrimary);

    final displayText = count > maxCount ? '$maxCount+' : count.toString();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -6,
          top: -4,
          child: AnimatedSwitcher(
            duration: AppDuration.fast,
            transitionBuilder: (child, animation) {
              return ScaleTransition(
                scale: animation,
                child: child,
              );
            },
            child: Container(
              key: ValueKey(count),
              padding: EdgeInsets.symmetric(
                horizontal: count > 9 ? 4 : 0,
              ),
              constraints: const BoxConstraints(
                minWidth: 16,
                minHeight: 16,
              ),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(AppRadius.full),
                boxShadow: [
                  BoxShadow(
                    color: bgColor.withAlpha(AppOpacity.semi),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  displayText,
                  style: TextStyle(
                    color: fgColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A dot indicator for navigation (no count, just presence)
class NavDot extends StatelessWidget {
  const NavDot({
    super.key,
    required this.child,
    required this.isVisible,
    this.color,
    this.pulseAnimation = false,
  });

  final Widget child;
  final bool isVisible;
  final Color? color;
  final bool pulseAnimation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!isVisible) {
      return child;
    }

    final dotColor = color ?? theme.colorScheme.primary;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: 0,
          top: 0,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: dotColor.withAlpha(AppOpacity.semi),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
