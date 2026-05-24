import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';

/// Editorial filter chip — pill shape, hairline border. When selected,
/// it switches to a white fill with dark text (the prototype's
/// `filter === id` rule). Optional [dotColor] LED on the left,
/// optional mono [count] on the right.
class MediaHubFilterChip extends StatefulWidget {
  const MediaHubFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dotColor,
    this.count,
  });

  final String label;
  final bool selected;

  /// When null the chip is disabled — pointer reverts to default,
  /// taps are ignored, but the chip still renders at full opacity
  /// (callers can wrap in `Opacity` if they want a visual dim).
  final VoidCallback? onTap;
  final Color? dotColor;
  final int? count;

  @override
  State<MediaHubFilterChip> createState() => _MediaHubFilterChipState();
}

class _MediaHubFilterChipState extends State<MediaHubFilterChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isSel = widget.selected;
    final bg = isSel
        ? AppColors.fg
        : (_hover ? AppColors.bgSurface : Colors.transparent);
    final fg = isSel ? AppColors.bgPage : AppColors.fg1;
    final borderColor = isSel ? AppColors.fg1 : AppColors.line;

    final enabled = widget.onTap != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppDuration.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: borderColor, width: 1),
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
                    boxShadow: [
                      BoxShadow(
                        color: widget.dotColor!.withValues(alpha: 0.5),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Text(
                widget.label,
                style: AppType.ui(
                  size: 12,
                  color: fg,
                  weight: FontWeight.w500,
                  height: 1.0,
                ),
              ),
              if (widget.count != null) ...[
                const SizedBox(width: 7),
                Text(
                  '${widget.count}',
                  style: AppType.mono(
                    size: 10,
                    color: fg.withValues(alpha: 0.6),
                    letterSpacing: 0.04,
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
