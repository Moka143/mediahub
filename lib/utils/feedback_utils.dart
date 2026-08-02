import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';

/// Severity of a transient notification. Drives the accent bar and icon only —
/// the surface itself stays the same dark panel for every kind, so a routine
/// success doesn't shout as loudly as a failure.
enum AppSnackBarKind { success, error, warning, info }

/// Utility class for showing snackbars with consistent styling.
///
/// Deliberately restrained: a compact centre-bottom panel on the app's own
/// surface colour, with severity carried by a 3px accent bar and a small icon
/// rather than by flooding the whole bar with a saturated fill.
class AppSnackBar {
  AppSnackBar._();

  /// Hard ceiling on how long any notification may stay up. Individual call
  /// sites can ask for less, never more.
  static const Duration maxDuration = Duration(seconds: 5);

  /// Notifications are a fixed, modest width rather than full-bleed — a
  /// desktop window is wide, and a bar spanning all of it for "Copied" reads
  /// as an error dialog.
  static const double maxWidth = 420;

  static void showSuccess(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) => showOn(
    ScaffoldMessenger.maybeOf(context),
    message: message,
    kind: AppSnackBarKind.success,
    actionLabel: actionLabel,
    onAction: onAction,
    duration: duration,
  );

  static void showError(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) => showOn(
    ScaffoldMessenger.maybeOf(context),
    message: message,
    kind: AppSnackBarKind.error,
    actionLabel: actionLabel,
    onAction: onAction,
    duration: duration,
  );

  static void showWarning(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) => showOn(
    ScaffoldMessenger.maybeOf(context),
    message: message,
    kind: AppSnackBarKind.warning,
    actionLabel: actionLabel,
    onAction: onAction,
    duration: duration,
  );

  static void showInfo(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) => showOn(
    ScaffoldMessenger.maybeOf(context),
    message: message,
    kind: AppSnackBarKind.info,
    actionLabel: actionLabel,
    onAction: onAction,
    duration: duration,
  );

  /// Show an undo snackbar for reversible actions.
  static void showUndo(
    BuildContext context, {
    required String message,
    required VoidCallback onUndo,
    Duration duration = maxDuration,
  }) => showOn(
    ScaffoldMessenger.maybeOf(context),
    message: message,
    kind: AppSnackBarKind.info,
    icon: Icons.undo_rounded,
    actionLabel: 'Undo',
    onAction: onUndo,
    duration: duration,
  );

  /// Show against an explicit messenger.
  ///
  /// Needed by call sites that fire after their own screen may already have
  /// been popped — the streaming callbacks reach for `rootScaffoldMessengerKey`
  /// for exactly that reason and have no live `BuildContext` of their own.
  static void showOn(
    ScaffoldMessengerState? messenger, {
    required String message,
    AppSnackBarKind kind = AppSnackBarKind.info,
    IconData? icon,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    if (messenger == null) return;

    final accent = _accentFor(kind);
    final hasAction = actionLabel != null && onAction != null;

    // Keep the panel inside the window on narrow layouts. SnackBar asserts
    // that width and margin are never both set, so width is the only lever.
    final screenWidth = MediaQuery.maybeOf(messenger.context)?.size.width;
    final width = screenWidth == null
        ? maxWidth
        : math.min(maxWidth, math.max(240.0, screenWidth - AppSpacing.xxxl));

    // Replace rather than queue. Without this a burst of events plays back
    // one bar at a time, and the last one can land seconds after the action
    // that caused it.
    messenger.hideCurrentSnackBar();

    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            // Severity accent — the only saturated colour on the panel.
            Container(
              width: 3,
              height: 22,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(AppRadius.xxs),
              ),
            ),
            const SizedBox(width: AppSpacing.sm + 2),
            Icon(icon ?? _iconFor(kind), color: accent, size: AppIconSize.xs),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.fg,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.bgSurfaceHigher,
        behavior: SnackBarBehavior.floating,
        width: width,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: const BorderSide(color: AppColors.lineStrong, width: 1),
        ),
        elevation: 0,
        // Flutter defaults `persist` to `action != null`, which makes any
        // actionable snackbar stay on screen forever — the only way out is
        // to press the action. That is what made "View Downloads" feel
        // stuck. Opt out explicitly so every notification times out.
        persist: false,
        duration: duration > maxDuration ? maxDuration : duration,
        action: hasAction
            ? SnackBarAction(
                label: actionLabel,
                textColor: accent,
                onPressed: onAction,
              )
            : null,
      ),
    );
  }

  static Color _accentFor(AppSnackBarKind kind) => switch (kind) {
    AppSnackBarKind.success => AppColors.ok,
    AppSnackBarKind.error => AppColors.err,
    AppSnackBarKind.warning => AppColors.warn,
    AppSnackBarKind.info => AppColors.accent,
  };

  static IconData _iconFor(AppSnackBarKind kind) => switch (kind) {
    AppSnackBarKind.success => Icons.check_circle_rounded,
    AppSnackBarKind.error => Icons.error_outline_rounded,
    AppSnackBarKind.warning => Icons.warning_amber_rounded,
    AppSnackBarKind.info => Icons.info_outline_rounded,
  };
}

/// Utility class for haptic feedback
class AppHaptics {
  AppHaptics._();

  /// Light impact feedback (for selection, toggle)
  static void lightImpact() {
    HapticFeedback.lightImpact();
  }

  /// Medium impact feedback (for button presses)
  static void mediumImpact() {
    HapticFeedback.mediumImpact();
  }

  /// Heavy impact feedback (for destructive actions)
  static void heavyImpact() {
    HapticFeedback.heavyImpact();
  }

  /// Selection click feedback
  static void selectionClick() {
    HapticFeedback.selectionClick();
  }

  /// Vibrate feedback (for errors)
  static void vibrate() {
    HapticFeedback.vibrate();
  }
}
