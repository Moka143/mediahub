import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Small monospace tag badge. The editorial design replaces "candy
/// chip" badges (pill-shaped colorful pills) with these — 10px
/// JetBrains Mono on a transparent background with a hairline border.
/// Quality, status, codec, network etc. all read as a single visual
/// language.
class EditorialBadge extends StatelessWidget {
  const EditorialBadge(
    this.label, {
    super.key,
    this.icon,
    this.iconSize = 9,
    this.compact = false,
    this.prominent = false,
    this.tone,
  });

  final String label;
  final IconData? icon;
  final double iconSize;

  /// Reduces padding for use inside dense rows.
  final bool compact;

  /// Larger type and padding for cinematic heroes, where the compact
  /// tags disappear against a backdrop next to an 80px title.
  final bool prominent;

  /// Tint for status-like badges (quality, torrent state, rating): drives
  /// both the text and a translucent border. Null is the neutral hairline.
  /// Use a colour that reads as text — `qualityTone`, `torrentStateTone`.
  final Color? tone;

  /// A [prominent] badge's padding: roomier top and bottom than a regular
  /// badge's 4, short of the 8 step. Public so the hero's status chip
  /// (`NextEpisodeChip`) can stand the same height as the badges under it.
  static const EdgeInsets prominentPadding = EdgeInsets.symmetric(
    horizontal: AppSpacing.md,
    vertical: 6,
  );

  @override
  Widget build(BuildContext context) {
    final textColor = tone ?? AppColors.fg;
    final borderColor = tone?.withValues(alpha: 0.5) ?? AppColors.line;

    // The compact size used to be 9px, which UiScale could take below 7 on a
    // high-DPI panel. The type scale's floor is 10.
    final fontSize = prominent ? AppType.sizeBody : AppType.minSize;
    final resolvedIconSize = prominent ? 14.0 : iconSize;
    final padding = prominent
        ? prominentPadding
        : EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.xs : AppSpacing.sm,
            vertical: compact ? AppSpacing.xxs : AppSpacing.xs,
          );

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: prominent
            ? AppColors.mediaBlack.withValues(alpha: 0.55)
            : AppColors.mediaBlack.withAlpha(AppOpacity.semi),
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
