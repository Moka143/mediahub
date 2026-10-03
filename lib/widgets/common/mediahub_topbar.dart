import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/mono_label.dart';
import '../editorial/serif_title.dart';
import 'hub_pressable.dart';

/// Editorial topbar — italic serif title, mono "crumb" on a hairline
/// vertical divider, trailing actions. Matches the `.tb` rule in the
/// prototype.
///
/// It used to carry a search field with a ⌘K hint. Neither caller ever
/// turned it on, and nothing handled ⌘K, so it is gone; search lives in each
/// browse screen's filter row.
class MediaHubTopBar extends StatelessWidget implements PreferredSizeWidget {
  const MediaHubTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.leading,
  });

  @override
  Size get preferredSize => const Size.fromHeight(64);

  /// Side gutter from the prototype's `.tb` rule, between the 24 and 32
  /// steps.
  static const double _gutter = 28;

  final String title;

  /// Rendered as the editorial "crumb" — uppercase mono on a divider.
  final String? subtitle;

  final List<Widget> actions;

  /// Optional widget placed before the title — typically a back button on
  /// pushed routes (e.g. Settings). Pass `null` on root screens.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Match preferredSize so the inner Row vertically centers inside
      // the full slot the Scaffold reserves; otherwise contents sit
      // top-aligned with ~30px of empty space below and the trailing
      // actions (settings button etc.) hug the macOS title bar instead
      // of sitting on the topbar's centerline.
      height: preferredSize.height,
      padding: const EdgeInsets.symmetric(horizontal: _gutter),
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          // Title row takes all available space on the left so the
          // trailing actions (Wrap below) get pushed against the right
          // edge. `Flexible` here would split free space with a
          // `Spacer` and leave the gear button stranded in the middle.
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Semantics(
                    header: true,
                    child: SerifTitle(
                      title,
                      size: AppType.sizePageTitle,
                      height: 1.0,
                      letterSpacing: -0.01,
                      maxLines: 1,
                    ),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(width: 14),
                  Container(width: 1, height: 14, color: AppColors.line),
                  const SizedBox(width: 14),
                  Flexible(
                    child: MonoLabel(
                      subtitle!,
                      letterSpacing: 0.12,
                      maxLines: 1,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
        ],
      ),
    );
  }
}

/// 32×32 ghost icon button. Used in the topbar action row.
///
/// Focusable, Enter/Space-activated and announced as a button with
/// [tooltip] as its name — the Settings gear and Back were mouse-only.
class MediaHubIconButton extends StatefulWidget {
  const MediaHubIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// For toggles (selection mode): drawn pressed-in, and announced as
  /// selected.
  final bool active;

  @override
  State<MediaHubIconButton> createState() => _MediaHubIconButtonState();
}

class _MediaHubIconButtonState extends State<MediaHubIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.xs);
    return HubPressable(
      onTap: widget.onPressed,
      tooltip: widget.tooltip,
      selected: widget.active ? true : null,
      borderRadius: radius,
      onHoverChanged: (h) => setState(() => _hover = h),
      child: AnimatedContainer(
        duration: AppDuration.fast,
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: widget.active
              ? AppColors.bgSurfaceHi
              : (_hover ? AppColors.bgSurface : Colors.transparent),
          borderRadius: radius,
          border: Border.all(
            color: widget.active ? AppColors.lineStrong : AppColors.line,
            width: 1,
          ),
        ),
        child: Icon(
          widget.icon,
          size: 14,
          color: widget.active || _hover ? AppColors.fg : AppColors.fg1,
        ),
      ),
    );
  }
}
