import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import 'mediahub_popup_menu.dart';

/// Generic sort/feed picker used at the top of browse screens.
///
/// Replaces the duplicated `_MoviesFeedSortPicker` /
/// `_FeedSortPicker` classes. Parameterized over the enum type so
/// movies and shows can share the same chrome.
class BrowseSortPicker<T> extends StatelessWidget {
  const BrowseSortPicker({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.tooltip = 'Sort feed',
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      initialValue: value,
      tooltip: tooltip,
      onSelected: onChanged,
      color: kMediaHubPopupColor,
      shape: kMediaHubPopupShape,
      itemBuilder: (_) => options
          .map(
            (option) => PopupMenuItem(
              value: option,
              child: Text(
                labelOf(option),
                style: AppType.ui(size: 12, color: AppColors.fg),
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort_rounded, size: 12, color: AppColors.fg2),
            const SizedBox(width: 6),
            Text(
              labelOf(value),
              style: AppType.ui(
                size: 12,
                color: AppColors.fg,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: AppColors.fg2,
            ),
          ],
        ),
      ),
    );
  }
}
