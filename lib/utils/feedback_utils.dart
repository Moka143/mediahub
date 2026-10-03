import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';

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
  /// sites can ask for less, never more. Long enough to read a four-line
  /// error and reach its action; anything that must not be missed belongs
  /// in a banner or dialog, not here.
  static const Duration maxDuration = Duration(seconds: 8);

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

  /// Errors stay up longest: they usually explain what to do next, and at
  /// 4 seconds a two-sentence message was gone before it had been read.
  static void showError(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 7),
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
    Duration duration = const Duration(seconds: 6),
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
    Duration duration = const Duration(seconds: 4),
  }) => showOn(
    ScaffoldMessenger.maybeOf(context),
    message: message,
    kind: AppSnackBarKind.info,
    actionLabel: actionLabel,
    onAction: onAction,
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
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    if (messenger == null) return;

    final accent = _accentFor(kind);
    final hasAction = actionLabel != null && onAction != null;
    final shown = duration ?? _defaultDurationFor(kind);
    // Errors and warnings explain what went wrong and what to do; two lines
    // cut them mid-sentence. Routine confirmations stay compact.
    final maxLines =
        kind == AppSnackBarKind.error || kind == AppSnackBarKind.warning
        ? 4
        : 2;

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
            Icon(_iconFor(kind), color: accent, size: AppIconSize.xs),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(
                  size: AppType.sizeBody,
                  color: AppColors.fg,
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
        duration: shown > maxDuration ? maxDuration : shown,
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

  static Duration _defaultDurationFor(AppSnackBarKind kind) => switch (kind) {
    AppSnackBarKind.success => const Duration(seconds: 3),
    AppSnackBarKind.info => const Duration(seconds: 4),
    AppSnackBarKind.warning => const Duration(seconds: 6),
    AppSnackBarKind.error => const Duration(seconds: 7),
  };

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
