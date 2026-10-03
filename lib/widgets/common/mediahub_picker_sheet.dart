import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/editorial.dart';
import 'hub_pressable.dart';

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
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.bgSurface,
      barrierColor: AppColors.barrier,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) =>
          MediaHubPickerSheet(title: title, icon: icon, child: child),
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
                // Drag handle is rendered by the global bottomSheetTheme
                // (`showDragHandle: true`) — no manual handle here.
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
                      Expanded(child: Text(title, style: AppType.title())),
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

/// One row in a [MediaHubPickerSheet]: leading icon, title, optional
/// subtitle, and a selected state (accent icon + accent text + soft accent
/// fill + check mark).
///
/// Built on [HubPressable], so the list can be walked with Tab and picked
/// with Enter or Space, and a screen reader hears each row as a button and
/// which one is current.
class PickerSheetTile extends StatefulWidget {
  const PickerSheetTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.selected = false,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<PickerSheetTile> createState() => _PickerSheetTileState();
}

class _PickerSheetTileState extends State<PickerSheetTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fg = selected ? AppColors.accent : AppColors.fg;
    final iconColor = selected ? AppColors.accent : AppColors.fg2;
    final bg = selected
        ? AppColors.accent.withAlpha(AppOpacity.subtle)
        : _hover
        ? AppColors.bgSurfaceHi
        : Colors.transparent;
    return HubPressable(
      onTap: widget.onTap,
      selected: selected,
      borderRadius: BorderRadius.zero,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: ColoredBox(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xxl,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(widget.icon, color: iconColor, size: AppIconSize.sm),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: AppType.ui(
                        size: AppType.sizeLead,
                        color: fg,
                        weight: selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(widget.subtitle!, style: AppType.caption()),
                    ],
                  ],
                ),
              ),
              if (selected)
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
      child: MonoLabel(label, letterSpacing: 0.12),
    );
  }
}
