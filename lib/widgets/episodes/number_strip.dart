import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
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
class NumberStrip extends StatelessWidget {
  const NumberStrip({super.key, required this.title, required this.items});

  /// Mono label in front of the chips — "SEASON", "EPISODE".
  final String title;
  final List<NumberStripItem> items;

  @override
  Widget build(BuildContext context) {
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
            title,
            style: AppType.mono(
              size: AppType.sizeLabel,
              color: AppColors.fg2,
              weight: FontWeight.w700,
              letterSpacing: 0.088,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in items) ...[
                    _NumberChip(item: item),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ),
        ],
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
