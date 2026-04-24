import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';

/// Utility class for showing snackbars with consistent styling
class AppSnackBar {
  AppSnackBar._();

  /// Show a success snackbar
  static void showSuccess(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    _show(
      context,
      message: message,
      icon: Icons.check_circle_rounded,
      backgroundColor: AppColors.success,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Show an error snackbar
  static void showError(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) {
    _show(
      context,
      message: message,
      icon: Icons.error_outline_rounded,
      backgroundColor: AppColors.error,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Show a warning snackbar
  static void showWarning(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    _show(
      context,
      message: message,
      icon: Icons.warning_amber_rounded,
      backgroundColor: AppColors.warning,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Show an info snackbar
  static void showInfo(
    BuildContext context, {
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    _show(
      context,
      message: message,
      icon: Icons.info_outline_rounded,
      backgroundColor: AppColors.info,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
  }

  /// Show an undo snackbar for reversible actions
  static void showUndo(
    BuildContext context, {
    required String message,
    required VoidCallback onUndo,
    Duration duration = const Duration(seconds: 5),
  }) {
    _show(
      context,
      message: message,
      icon: Icons.undo_rounded,
      backgroundColor: Theme.of(context).colorScheme.inverseSurface,
      textColor: Theme.of(context).colorScheme.onInverseSurface,
      actionLabel: 'Undo',
      onAction: onUndo,
      duration: duration,
    );
  }

  static void _show(
    BuildContext context, {
    required String message,
    required IconData icon,
    required Color backgroundColor,
    Color textColor = Colors.white,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: textColor, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: textColor),
              ),
            ),
          ],
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(AppSpacing.screenPadding),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        duration: duration,
        action: actionLabel != null && onAction != null
            ? SnackBarAction(
                label: actionLabel,
                textColor: textColor,
                onPressed: onAction,
              )
            : null,
      ),
    );
  }
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

/// Animated button that provides visual feedback on press
class AnimatedPressButton extends StatefulWidget {
  const AnimatedPressButton({
    super.key,
    required this.child,
    this.onPressed,
    this.scaleDown = 0.95,
    this.duration = const Duration(milliseconds: 100),
    this.hapticFeedback = true,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final double scaleDown;
  final Duration duration;
  final bool hapticFeedback;

  @override
  State<AnimatedPressButton> createState() => _AnimatedPressButtonState();
}

class _AnimatedPressButtonState extends State<AnimatedPressButton> {
  bool _isPressed = false;

  void _handleTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
  }

  void _handleTapUp(TapUpDetails details) {
    setState(() => _isPressed = false);
    if (widget.hapticFeedback) {
      AppHaptics.lightImpact();
    }
    widget.onPressed?.call();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onPressed != null ? _handleTapDown : null,
      onTapUp: widget.onPressed != null ? _handleTapUp : null,
      onTapCancel: widget.onPressed != null ? _handleTapCancel : null,
      child: AnimatedScale(
        scale: _isPressed ? widget.scaleDown : 1.0,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// Pulsing animation for drawing attention to elements
class PulseAnimation extends StatefulWidget {
  const PulseAnimation({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 1500),
    this.minScale = 0.95,
    this.maxScale = 1.05,
  });

  final Widget child;
  final Duration duration;
  final double minScale;
  final double maxScale;

  @override
  State<PulseAnimation> createState() => _PulseAnimationState();
}

class _PulseAnimationState extends State<PulseAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat(reverse: true);

    _animation = Tween<double>(
      begin: widget.minScale,
      end: widget.maxScale,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Transform.scale(
          scale: _animation.value,
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
