import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_typography.dart';
import '../editorial/mono_label.dart';
import '../editorial/serif_title.dart';

/// Editorial section header. The cinematic redesign renders this as
/// an italic Instrument Serif title with an optional mono "tag" right
/// after, and trailing widgets on the right (e.g. "see all →" link).
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    this.onTap,
    this.padding,
    this.showDivider = false,
    this.large = false,
    this.tag,
  });

  final String title;

  /// Optional leading icon — rendered subdued in the editorial style.
  final IconData? icon;

  /// Optional trailing widget.
  final Widget? trailing;

  /// Optional tap callback (rarely used in the editorial language).
  final VoidCallback? onTap;

  /// Custom padding. Defaults to the prototype's 36/16 top/bottom rhythm.
  final EdgeInsetsGeometry? padding;

  /// Show a thin divider above the header (rare — usually the section
  /// itself is separated by the implicit serif rhythm).
  final bool showDivider;

  /// Use a larger title size (28 vs 22).
  final bool large;

  /// Mono "tag" subtitle rendered after the title (e.g. "5 items").
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: AppColors.fg3),
            const SizedBox(width: 10),
          ],
          SerifTitle(
            title,
            size: large ? 28 : 22,
            height: 1.0,
          ),
          if (tag != null) ...[
            const SizedBox(width: 14),
            MonoLabel(tag!, color: AppColors.fg3),
          ],
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );

    Widget result = onTap != null
        ? Material(
            color: Colors.transparent,
            child: InkWell(onTap: onTap, child: content),
          )
        : content;

    if (showDivider) {
      result = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, thickness: 1, color: AppColors.line),
          result,
        ],
      );
    }
    return result;
  }
}

/// Settings section header — small uppercase mono label, accent color.
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.padding,
  });

  final String title;
  final IconData? icon;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.only(left: 20, right: 20, top: 28, bottom: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: AppColors.accent),
            const SizedBox(width: 8),
          ],
          Text(
            title.toUpperCase(),
            style: AppType.mono(
              size: 10,
              color: AppColors.accent,
              letterSpacing: 0.14,
              weight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
