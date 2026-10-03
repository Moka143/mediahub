import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import 'hub_pressable.dart';

/// Compact search pill used in the Movies / TV Shows browse filter rows.
///
/// Matches the visual style of the Transfers search pill in the navigation
/// shell — same width / height / colors — so the three browse surfaces
/// feel consistent.
class BrowseSearchPill extends StatelessWidget {
  const BrowseSearchPill({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hint = 'Search…',
    this.width = 220,
    this.focusNode,
  });

  final TextEditingController controller;

  /// Lets the owner keep focus and caret across rebuilds that would
  /// otherwise recreate the field (the Transfers screen needs this).
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final String hint;

  /// Fixed width in logical pixels. Pass `null` to let the pill fill
  /// whatever width its parent gives it (useful inside `Expanded`).
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 12, color: AppColors.fg2),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              cursorColor: AppColors.accent,
              // Height and tracking are the ones the field inherited from the
              // theme's body style, spelled out: the line height is what sets
              // the pill's height.
              style: AppType.ui(
                size: AppType.sizeCaption,
                color: AppColors.fg,
                height: 1.5,
                letterSpacing: 0.5,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: AppType.ui(
                  size: AppType.sizeCaption,
                  color: AppColors.fg2,
                  height: 1.5,
                  letterSpacing: 0.5,
                ),
                filled: false,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            HubPressable(
              tooltip: 'Clear search',
              onTap: () {
                controller.clear();
                onChanged('');
              },
              // 24×24 hit target around a 12px glyph — the bare icon was
              // about 16×12 and easy to miss.
              child: const SizedBox(
                width: 24,
                height: 24,
                child: Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: AppColors.fg2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
