import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial.dart';

/// Editorial bottom-sheet primitive for "pick one from a list" flows —
/// subtitle / audio / speed pickers in the video player, etc. Differs
/// from [MediaHubConfirmDialog] in shape (slides up from the bottom)
/// and intent (no destructive vs primary action, just selection).
///
/// Render the body with [PickerSheetTile] for the standard rows and
/// [PickerSheetSection] for mono uppercase section headers between
/// groups of tiles.
class MediaHubPickerSheet extends StatelessWidget {
  const MediaHubPickerSheet({
    super.key,
    required this.title,
    this.icon,
    required this.child,
  });

  final IconData? icon;
  final String title;
  final Widget child;

  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    IconData? icon,
    required Widget child,
    bool scrollControlled = false,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      isScrollControlled: scrollControlled,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      builder: (_) => MediaHubPickerSheet(
        title: title,
        icon: icon,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
          border: Border(
            top: BorderSide(color: AppColors.line),
            left: BorderSide(color: AppColors.line),
            right: BorderSide(color: AppColors.line),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle — subtle, indicates draggable.
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: AppSpacing.sm),
                    width: 36,
                    height: 3,
                    decoration: BoxDecoration(
                      color: AppColors.line,
                      borderRadius: BorderRadius.circular(AppRadius.full),
                    ),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xxl,
                    AppSpacing.lg,
                    AppSpacing.xxl,
                    AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      if (icon != null) ...[
                        Icon(
                          icon,
                          color: AppColors.accent,
                          size: AppIconSize.md,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                      SerifTitle(title, size: 22, height: 1.05),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.line),
                child,
                const SizedBox(height: AppSpacing.md),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row in a [MediaHubPickerSheet]. Renders as a tappable row with
/// leading icon, title, optional subtitle, optional trailing widget,
/// and a selected state (accent icon + accent text + soft accent fill).
class PickerSheetTile extends StatelessWidget {
  const PickerSheetTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.selected = false,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.accent : AppColors.fg;
    final iconColor = selected ? AppColors.accent : AppColors.fg2;
    return Material(
      color: selected ? AppColors.accent.withValues(alpha: 0.08) : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xxl,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: AppIconSize.sm),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: AppType.ui(
                        size: 14,
                        color: fg,
                        weight: selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: AppType.ui(
                          size: 12,
                          color: AppColors.fg2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.sm),
                trailing!,
              ],
              if (selected && trailing == null)
                const Icon(
                  Icons.check_rounded,
                  color: AppColors.accent,
                  size: AppIconSize.sm,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mono uppercase section header rendered between groups of
/// [PickerSheetTile]s — e.g. "EMBEDDED" vs "OPENSUBTITLES".
class PickerSheetSection extends StatelessWidget {
  const PickerSheetSection({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xxl,
        AppSpacing.md,
        AppSpacing.xxl,
        AppSpacing.xs,
      ),
      child: MonoLabel(
        label,
        color: AppColors.fg3,
        letterSpacing: 0.12,
      ),
    );
  }
}
