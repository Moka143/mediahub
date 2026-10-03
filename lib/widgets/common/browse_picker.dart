import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import 'mediahub_popup_menu.dart';

/// A drop-down at the top of a browse screen — the genre picker and the feed
/// ("Sort") picker. Parameterised over the option type so the two share one
/// look.
class BrowsePicker<T> extends StatelessWidget {
  const BrowsePicker({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    required this.icon,
    required this.tooltip,
    this.enabled = true,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  /// Leads the button, so it says what is being picked before the value
  /// does: "Drama" alone could be either picker.
  final IconData icon;
  final String tooltip;

  /// Off while search results are showing, which neither picker narrows.
  final bool enabled;

  /// Off the 4/8 steps on purpose: the picker is the tallest control in an
  /// idle browse filter row, so this sets the row's height.
  static const double _padV = 6;

  /// Desktop menu rows. At Material's 48, TMDB's full genre list ran taller
  /// than most windows.
  static const double _itemHeight = 36;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      initialValue: value,
      tooltip: tooltip,
      enabled: enabled,
      onSelected: onChanged,
      color: kMediaHubPopupColor,
      shape: kMediaHubPopupShape,
      // Drop below the button, as a desktop drop-down does. Material's
      // default opens the menu over it, hiding the button being changed.
      position: PopupMenuPosition.under,
      offset: const Offset(0, AppSpacing.xs),
      itemBuilder: (_) => [
        for (final option in options)
          PopupMenuItem<T>(
            value: option,
            height: _itemHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    labelOf(option),
                    style: AppType.ui(
                      size: AppType.sizeCaption,
                      color: AppColors.fg,
                    ),
                  ),
                ),
                if (option == value)
                  const Icon(
                    Icons.check_rounded,
                    size: AppIconSize.xs,
                    color: AppColors.accent,
                  ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: _padV,
        ),
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          border: Border.all(color: AppColors.line),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: AppColors.fg2),
            const SizedBox(width: 6),
            Text(
              labelOf(value),
              style: AppType.ui(
                size: AppType.sizeCaption,
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
