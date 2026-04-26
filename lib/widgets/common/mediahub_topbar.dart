import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// MediaHub-styled in-page header — large display title, secondary
/// subtitle, optional center search field, and a row of trailing
/// actions on the right. Matches the `TopBar` component from the
/// design's `components.jsx`.
///
/// Implements [PreferredSizeWidget] so it can drop into Scaffold's
/// `appBar` slot without ceremony.
class MediaHubTopBar extends StatelessWidget implements PreferredSizeWidget {
  const MediaHubTopBar({
    super.key,
    required this.title,
    this.subtitle,
    this.showSearch = true,
    this.searchHint = 'Search across everything — titles, actors, file names…',
    this.onSearchChanged,
    this.searchController,
    this.actions = const [],
  });

  @override
  Size get preferredSize {
    // 16+16 vertical padding + ~46px content (title + optional subtitle)
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    return Size.fromHeight(hasSubtitle ? 78 : 64);
  }

  final String title;
  final String? subtitle;
  final bool showSearch;
  final String searchHint;
  final ValueChanged<String>? onSearchChanged;
  final TextEditingController? searchController;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Title + subtitle stack — `Expanded` so the title soaks up
          // all leftover horizontal space, which pins the actions row
          // to the true right edge regardless of title length. (Using
          // Flexible+Spacer here split the row 50/50 and made actions
          // float toward the middle.)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.44,
                    height: 1.15,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF7A7A92),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          if (showSearch) ...[
            const SizedBox(width: AppSpacing.lg),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: _SearchField(
                hint: searchHint,
                controller: searchController,
                onChanged: onSearchChanged,
              ),
            ),
          ],

          if (actions.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.md),
            // Actions can wrap onto a tighter row but keep their
            // intrinsic widths — avoids the Row overflow we hit when
            // the action list grew with connection status etc.
            Wrap(
              spacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
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
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: const Color(0x0FFFFFFF), width: 1),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 6,
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 14, color: Color(0xFF7A7A92)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorColor: AppColors.seedColor,
              style: const TextStyle(fontSize: 13, color: Color(0xFFF4F4F8)),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: Color(0x66B4B4C8),
                ),
                filled: false,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const _Kbd(label: '⌘K'),
        ],
      ),
    );
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.bgSurfaceHi,
        border: Border.all(color: const Color(0x0FFFFFFF)),
        borderRadius: BorderRadius.circular(AppRadius.xxs),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xFF7A7A92),
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// Compact 34×34 icon button used in the TopBar action row. Subtle
/// ghost background that lights up on hover, matches the design's
/// `IconBtn` component from `components.jsx`.
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
    final dotColor = widget.dotColor ?? AppColors.accentTertiary;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: widget.active
                  ? AppColors.bgSurfaceHi
                  : (_hover ? Colors.white.withAlpha(10) : Colors.transparent),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: widget.active
                  ? Border.all(color: const Color(0x1AFFFFFF))
                  : null,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Icon(
                    widget.icon,
                    size: 16,
                    color: const Color(0xFFB4B4C8),
                  ),
                ),
                if (widget.hasDot)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: dotColor.withAlpha(120),
                            blurRadius: 6,
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
