import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

/// Pill-shaped filter chip styled to match the MediaHub design.
///
/// When `selected`, the chip uses a soft accent background, an accent
/// foreground color, and a hairline accent border. Optional `dotColor`
/// renders a status dot on the left, and `count` renders a small mono
/// count badge on the right (e.g. "Downloading · 3").
class MediaHubFilterChip extends StatefulWidget {
  const MediaHubFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dotColor,
    this.count,
    this.accentColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dotColor;
  final int? count;
  final Color? accentColor;

  @override
  State<MediaHubFilterChip> createState() => _MediaHubFilterChipState();
}

class _MediaHubFilterChipState extends State<MediaHubFilterChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final accent =
        widget.accentColor ?? widget.dotColor ?? AppColors.seedColor;
    final isSel = widget.selected;
    final bg = isSel
        ? accent.withAlpha(0x24)
        : (_hover ? Colors.white.withAlpha(10) : Colors.transparent);
    final fg = isSel ? accent : const Color(0xFFB4B4C8);
    final borderColor =
        isSel ? accent.withAlpha(0x66) : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.dotColor != null) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              if (widget.count != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: isSel
                        ? accent.withAlpha(0x40)
                        : AppColors.bgSurfaceHi,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Text(
                    '${widget.count}',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: isSel ? accent : const Color(0xFF7A7A92),
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
