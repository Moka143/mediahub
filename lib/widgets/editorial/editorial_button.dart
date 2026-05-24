import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Editorial button — three kinds (accent, primary, ghost) and two
/// sizes (default, lg). Replaces Material's ElevatedButton/FilledButton
/// pair so we can match the prototype's exact metrics and weight.
enum EditorialButtonKind {
  /// Cinema-orange filled — the "do the thing" CTA. Used sparingly.
  accent,

  /// Off-white filled — secondary CTA (Resume, Play).
  primary,

  /// Surface-tinted with hairline border — tertiary action.
  ghost,

  /// Subtle — surface fill, hairline border, low emphasis.
  subtle,

  /// Outline-only — for icon-led ghost actions on backdrops.
  outlined,

  /// Red filled — destructive confirm (Delete, Reset).
  danger,
}

class EditorialButton extends StatelessWidget {
  const EditorialButton({
    super.key,
    required this.label,
    this.icon,
    this.kind = EditorialButtonKind.subtle,
    this.onPressed,
    this.large = false,
    this.tooltip,
    this.expand = false,
  });

  final String label;
  final IconData? icon;
  final EditorialButtonKind kind;
  final VoidCallback? onPressed;
  final bool large;
  final String? tooltip;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final padH = large ? 22.0 : 16.0;
    final padV = large ? 12.0 : 8.0;
    final fontSize = large ? 14.0 : 13.0;
    final weight = kind == EditorialButtonKind.accent
        ? FontWeight.w600
        : FontWeight.w500;

    final (bg, fg, border) = switch (kind) {
      EditorialButtonKind.accent => (
        AppColors.accent,
        AppColors.bgPage,
        AppColors.accent,
      ),
      EditorialButtonKind.primary => (
        AppColors.fg,
        AppColors.bgPage,
        AppColors.fg,
      ),
      EditorialButtonKind.ghost => (
        Colors.transparent,
        AppColors.fg,
        AppColors.lineStrong,
      ),
      EditorialButtonKind.subtle => (
        AppColors.bgSurface,
        AppColors.fg,
        AppColors.line,
      ),
      EditorialButtonKind.outlined => (
        Colors.transparent,
        AppColors.fg1,
        AppColors.line,
      ),
      EditorialButtonKind.danger => (
        AppColors.err,
        Colors.white,
        AppColors.err,
      ),
    };

    final child = Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        side: BorderSide(color: border, width: 1),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: expand
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(icon, size: large ? 16 : 14, color: fg),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: AppType.ui(
                  size: fontSize,
                  color: fg,
                  weight: weight,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final wrapped = tooltip != null
        ? Tooltip(message: tooltip!, child: child)
        : child;
    return expand ? wrapped : IntrinsicWidth(child: wrapped);
  }
}

/// 32×32 hairline-bordered icon button. The chrome's go-to for
/// secondary actions in the topbar / titlebar.
class EditorialIconButton extends StatelessWidget {
  const EditorialIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 32,
    this.iconSize = 14,
    this.color = AppColors.fg1,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final btn = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: active ? AppColors.accentSoft : AppColors.bgSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
          side: BorderSide(
            color: active ? AppColors.accent : AppColors.line,
            width: 1,
          ),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: Center(
            child: Icon(
              icon,
              size: iconSize,
              color: active ? AppColors.accent : color,
            ),
          ),
        ),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: btn) : btn;
  }
}
