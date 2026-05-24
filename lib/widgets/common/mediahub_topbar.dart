import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../editorial/mono_label.dart';
import '../editorial/serif_title.dart';

/// Editorial topbar — italic serif title, mono "crumb" on a hairline
/// vertical divider, optional search field, trailing actions.
/// Matches the `.tb` rule in the prototype.
class MediaHubTopBar extends StatelessWidget implements PreferredSizeWidget {
  const MediaHubTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.showSearch = true,
    this.searchHint = 'Search shows, movies, magnet links…',
    this.onSearchChanged,
    this.searchController,
    this.actions = const [],
    this.leading,
  });

  @override
  Size get preferredSize => const Size.fromHeight(64);

  final String title;

  /// Rendered as the editorial "crumb" — uppercase mono on a divider.
  final String? subtitle;

  final bool showSearch;
  final String searchHint;
  final ValueChanged<String>? onSearchChanged;
  final TextEditingController? searchController;
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
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 12),
          ],
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
                  child: SerifTitle(
                    title,
                    size: 28,
                    height: 1.0,
                    letterSpacing: -0.01,
                    maxLines: 1,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(width: 14),
                  Container(width: 1, height: 14, color: AppColors.line),
                  const SizedBox(width: 14),
                  Flexible(
                    child: MonoLabel(
                      subtitle!,
                      color: AppColors.fg3,
                      letterSpacing: 0.12,
                      maxLines: 1,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showSearch) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320, minWidth: 220),
              child: _SearchField(
                hint: searchHint,
                controller: searchController,
                onChanged: onSearchChanged,
              ),
            ),
            const SizedBox(width: 10),
          ],
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

class _SearchField extends StatelessWidget {
  const _SearchField({this.hint, this.controller, this.onChanged});

  final String? hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.line, width: 1),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 14, color: AppColors.fg3),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorColor: AppColors.accent,
              style: AppType.ui(size: 12, color: AppColors.fg),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: AppType.ui(size: 12, color: AppColors.fg3),
                filled: false,
              ),
            ),
          ),
          const SizedBox(width: 6),
          _Kbd(label: _isMac() ? '⌘K' : 'Ctrl+K'),
        ],
      ),
    );
  }

  static bool _isMac() {
    // Best-effort — defaults to Mac if unknown so UI looks right on
    // the primary dev target. Doesn't affect functionality.
    return defaultTargetPlatform == TargetPlatform.macOS;
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.line, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: AppType.mono(
          size: 10,
          color: AppColors.fg3,
          letterSpacing: 0.04,
        ),
      ),
    );
  }
}

/// 32×32 ghost icon button. Used in the topbar action row.
class MediaHubIconButton extends StatefulWidget {
  const MediaHubIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.hasDot = false,
    this.dotColor,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool hasDot;
  final Color? dotColor;
  final bool active;

  @override
  State<MediaHubIconButton> createState() => _MediaHubIconButtonState();
}

class _MediaHubIconButtonState extends State<MediaHubIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final dotColor = widget.dotColor ?? AppColors.accent;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: widget.active
                  ? AppColors.bgSurfaceHi
                  : (_hover ? AppColors.bgSurface : Colors.transparent),
              borderRadius: BorderRadius.circular(AppRadius.xs),
              border: Border.all(
                color: widget.active ? AppColors.lineStrong : AppColors.line,
                width: 1,
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Icon(
                    widget.icon,
                    size: 14,
                    color: widget.active ? AppColors.fg : AppColors.fg1,
                  ),
                ),
                if (widget.hasDot)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: dotColor.withValues(alpha: 0.6),
                            blurRadius: 5,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
