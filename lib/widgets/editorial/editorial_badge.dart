import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Small monospace tag badge. The editorial design replaces "candy
/// chip" badges (pill-shaped colorful pills) with these — 10px
/// JetBrains Mono on a transparent background with a hairline border.
/// Quality, status, codec, network etc. all read as a single visual
/// language.
enum BadgeKind {
  /// Neutral hairline — for inert metadata (year, runtime, codec).
  neutral,

  /// Accent — emphasized (the one you want to draw attention to).
  accent,

  /// Ready / seeding / complete.
  ok,

  /// Queued / checking / pending.
  warn,

  /// Error / missing.
  err,
}

class EditorialBadge extends StatelessWidget {
  const EditorialBadge(
    this.label, {
    super.key,
    this.kind = BadgeKind.neutral,
    this.icon,
    this.iconSize = 9,
    this.compact = false,
    this.prominent = false,
    this.tone,
  });

  final String label;
  final BadgeKind kind;
  final IconData? icon;
  final double iconSize;

  /// Reduces padding for use inside dense rows.
  final bool compact;

  /// Larger type and padding for cinematic heroes, where the compact
  /// 9px tags disappear against a backdrop next to an 80px title.
  final bool prominent;

  /// Escape hatch for tinted-but-still-mono badges (quality colors,
  /// torrent-state colors, rating colors). When non-null, this color
  /// drives both the text and a translucent border, overriding [kind].
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final (textColor, borderColor) = tone != null
        ? (tone!, tone!.withValues(alpha: 0.5))
        : switch (kind) {
            BadgeKind.neutral => (AppColors.fg, AppColors.line),
            BadgeKind.accent => (AppColors.accent, AppColors.accent),
            BadgeKind.ok => (AppColors.ok, const Color(0x666ED274)),
            BadgeKind.warn => (AppColors.warn, const Color(0x66F3B94C)),
            BadgeKind.err => (AppColors.err, const Color(0x80FF5F5B)),
          };

    final fontSize = prominent ? 13.0 : compact ? 9.0 : 10.0;
    final resolvedIconSize = prominent ? 14.0 : iconSize;
    final padding = prominent
        ? const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6)
        : EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.xs : AppSpacing.sm,
            vertical: compact ? AppSpacing.xxs : AppSpacing.xs,
          );

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: prominent ? 0.55 : 0.4),
        borderRadius: BorderRadius.circular(
          prominent ? AppRadius.xs : AppRadius.xxs,
        ),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: resolvedIconSize, color: textColor),
            const SizedBox(width: 4),
          ],
          Text(
            label.toUpperCase(),
            style: AppType.mono(
              size: fontSize,
              color: textColor,
              weight: prominent ? FontWeight.w600 : FontWeight.w500,
              letterSpacing: 0.05,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
