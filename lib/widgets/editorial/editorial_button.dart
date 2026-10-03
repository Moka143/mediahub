import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../common/hub_pressable.dart';

/// Editorial button kinds. Replaces Material's ElevatedButton/FilledButton
/// pair so we can match the prototype's exact metrics and weight.
enum EditorialButtonKind {
  /// Cinema-orange filled — the "do the thing" CTA. Used sparingly.
  accent,

  /// Surface-tinted with hairline border — tertiary action.
  ghost,

  /// Subtle — surface fill, hairline border, low emphasis.
  subtle,

  /// Red filled — destructive confirm (Delete, Reset).
  danger,
}

/// Editorial button — four kinds, two sizes (default, [large]).
///
/// Built on [HubPressable], so it takes keyboard focus (with a visible
/// ring), activates on Enter and Space, and is announced as a button. A null
/// [onPressed] disables it: dimmed, out of the focus order, arrow cursor —
/// it used to look exactly as clickable as an enabled one.
class EditorialButton extends StatefulWidget {
  const EditorialButton({
    super.key,
    required this.label,
    this.icon,
    this.kind = EditorialButtonKind.subtle,
    this.onPressed,
    this.large = false,
    this.expand = false,
    this.autofocus = false,
  });

  final String label;
  final IconData? icon;
  final EditorialButtonKind kind;
  final VoidCallback? onPressed;
  final bool large;
  final bool expand;

  /// Take keyboard focus when first shown — the safe default action of a
  /// dialog, for example.
  final bool autofocus;

  @override
  State<EditorialButton> createState() => _EditorialButtonState();
}

class _EditorialButtonState extends State<EditorialButton> {
  bool _hover = false;

  /// Side padding of a large button: the prototype's metric, between the 20
  /// and 24 steps.
  static const double _largePadH = 22;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final padH = widget.large ? _largePadH : AppSpacing.lg;
    final padV = widget.large ? AppSpacing.md : AppSpacing.sm;
    final fontSize = widget.large ? AppType.sizeLead : AppType.sizeBody;
    final weight = widget.kind == EditorialButtonKind.accent
        ? FontWeight.w600
        : FontWeight.w500;

    // Text on a filled kind is onAccent (dark): white on the red danger fill
    // was 3.0:1, on the orange 2.7:1.
    final (bg, fg, border) = switch (widget.kind) {
      EditorialButtonKind.accent => (
        AppColors.accent,
        AppColors.onAccent,
        AppColors.accent,
      ),
      EditorialButtonKind.ghost => (
        _hover && enabled ? AppColors.bgSurface : Colors.transparent,
        AppColors.fg,
        AppColors.lineStrong,
      ),
      EditorialButtonKind.subtle => (
        _hover && enabled ? AppColors.bgSurfaceHi : AppColors.bgSurface,
        AppColors.fg,
        AppColors.line,
      ),
      EditorialButtonKind.danger => (
        AppColors.err,
        AppColors.onAccent,
        AppColors.err,
      ),
    };
    final filled =
        widget.kind == EditorialButtonKind.accent ||
        widget.kind == EditorialButtonKind.danger;
    final radius = BorderRadius.circular(AppRadius.xs);

    Widget button = AnimatedContainer(
      duration: AppDuration.fast,
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: Border.all(color: border, width: 1),
      ),
      // Filled kinds brighten on hover instead of changing colour.
      foregroundDecoration: filled && _hover && enabled
          ? BoxDecoration(color: AppColors.glassFill, borderRadius: radius)
          : null,
      child: Row(
        mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: widget.expand
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: widget.large ? 16 : 14, color: fg),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.ui(
                size: fontSize,
                color: fg,
                weight: weight,
                height: 1.0,
              ),
            ),
          ),
        ],
      ),
    );

    if (!enabled) button = Opacity(opacity: 0.4, child: button);

    final pressable = HubPressable(
      onTap: widget.onPressed,
      autofocus: widget.autofocus,
      borderRadius: radius,
      focusRingColor: filled ? AppColors.fg : AppColors.accent,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: button,
    );
    return widget.expand ? pressable : IntrinsicWidth(child: pressable);
  }
}

/// Hairline-bordered icon button, 32×32 by default. The chrome's go-to for
/// secondary actions. Always give it a [tooltip]: an icon has no text for a
/// screen reader to announce, and the tooltip doubles as its label.
class EditorialIconButton extends StatefulWidget {
  const EditorialIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 32,
    this.iconSize = 14,
    this.color = AppColors.fg1,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;
  final double iconSize;
  final Color color;

  @override
  State<EditorialIconButton> createState() => _EditorialIconButtonState();
}

class _EditorialIconButtonState extends State<EditorialIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final radius = BorderRadius.circular(AppRadius.xs);
    return HubPressable(
      onTap: widget.onPressed,
      tooltip: widget.tooltip,
      borderRadius: radius,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: AnimatedContainer(
          duration: AppDuration.fast,
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: _hover && enabled
                ? AppColors.bgSurfaceHi
                : AppColors.bgSurface,
            borderRadius: radius,
            border: Border.all(color: AppColors.line, width: 1),
          ),
          child: Icon(widget.icon, size: widget.iconSize, color: widget.color),
        ),
      ),
    );
  }
}
