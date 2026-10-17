import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../common/horizontal_paging.dart';
import '../common/hub_pressable.dart';

/// One chip in a [NumberStrip].
@immutable
class NumberStripItem {
  const NumberStripItem({
    required this.label,
    required this.onTap,
    required this.semanticLabel,
    this.selected = false,
    this.tone,
    this.tinted = false,
  });

  /// What the chip shows — `01`, `SP`.
  final String label;
  final VoidCallback onTap;

  /// Read by screen readers: "Season 2", "Episode 5, downloaded".
  final String semanticLabel;

  /// The current one — drawn filled in the accent.
  final bool selected;

  /// A status colour: a faint border and a stripe along the bottom edge.
  final Color? tone;

  /// Fill the chip with a wash of [tone] instead of the stripe — for "done"
  /// states that should read at a glance.
  final bool tinted;
}

/// A labelled, horizontally scrolling strip of 36×28 numbered chips.
///
/// Seasons and the episode quick-jump were the same strip written twice
/// (`SeasonTabs` / `EpisodePicker`), both on bare GestureDetectors — no
/// focus, no keyboard, no button semantics.
///
/// A long show's chips run past the drawer's edge, and a mouse wheel scrolls
/// vertically, so a strip that overflows fades the side with more and gets
/// an arrow at each end. Not `HoverScrollRow`: its arrows are 40 px buttons
/// laid over the content — taller than these chips, and wide enough to hide
/// one. The scrolling behind the arrows is shared ([HorizontalPaging]).
class NumberStrip extends StatefulWidget {
  const NumberStrip({super.key, required this.title, required this.items});

  /// Mono label in front of the chips — "SEASON", "EPISODE".
  final String title;
  final List<NumberStripItem> items;

  @override
  State<NumberStrip> createState() => _NumberStripState();
}

class _NumberStripState extends State<NumberStrip>
    with HorizontalPaging<NumberStrip> {
  @override
  Widget build(BuildContext context) {
    final overflows = canScrollBack || canScrollForward;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      child: Row(
        children: [
          Text(
            widget.title,
            style: AppType.mono(
              size: AppType.sizeLabel,
              color: AppColors.fg2,
              weight: FontWeight.w700,
              letterSpacing: 0.088,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (overflows)
            _StripArrow(
              left: true,
              onTap: canScrollBack ? () => page(forward: false) : null,
            ),
          Expanded(
            child: trackEdges(
              fadeExtent: AppSpacing.xxl,
              SingleChildScrollView(
                controller: pagingController,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final item in widget.items) ...[
                      _NumberChip(item: item),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (overflows)
            _StripArrow(
              left: false,
              onTap: canScrollForward ? () => page(forward: true) : null,
            ),
        ],
      ),
    );
  }
}

/// One end of a strip that overflows. Stays, inert, at an end with nothing
/// more past it, so the chips do not shift each time an arrow would come or
/// go.
class _StripArrow extends StatelessWidget {
  const _StripArrow({required this.left, required this.onTap});

  final bool left;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return HubPressable(
      onTap: onTap,
      tooltip: onTap == null
          ? null
          : (left ? 'Scroll back' : 'Scroll for more'),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: 24,
        height: 28,
        child: Icon(
          left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
          size: 20,
          color: onTap == null ? AppColors.fg3 : AppColors.fg1,
        ),
      ),
    );
  }
}

class _NumberChip extends StatelessWidget {
  const _NumberChip({required this.item});

  final NumberStripItem item;

  @override
  Widget build(BuildContext context) {
    final tone = item.tone;
    final Color fill;
    final Color border;
    final Color text;
    if (item.selected) {
      fill = AppColors.accent;
      border = AppColors.accent;
      text = AppColors.onAccent;
    } else if (tone != null && item.tinted) {
      fill = tone.withValues(alpha: 0.15);
      border = tone.withValues(alpha: 0.5);
      text = tone;
    } else {
      fill = AppColors.bgSurface;
      border = tone?.withValues(alpha: 0.3) ?? AppColors.line;
      text = AppColors.fg1;
    }

    return HubPressable(
      onTap: item.onTap,
      selected: item.selected,
      semanticLabel: item.semanticLabel,
      excludeChildSemantics: true,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: ClipRRect(
        // The stripe needs hard clipping so the rounded corners don't leak
        // its colour past the radius.
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          width: 36,
          height: 28,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: border, width: 1),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          alignment: Alignment.center,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                item.label,
                style: AppType.mono(
                  size: AppType.sizeCaption,
                  color: text,
                  weight: FontWeight.w700,
                ),
              ),
              if (tone != null && !item.tinted && !item.selected)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(height: 2, color: tone),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
