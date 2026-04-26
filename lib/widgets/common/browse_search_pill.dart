import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';

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
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: const Color(0x0FFFFFFF)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 12, color: Color(0xFF7A7A92)),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorColor: AppColors.seedColor,
              style: const TextStyle(fontSize: 12, color: Color(0xFFF4F4F8)),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(
                  fontSize: 12,
                  color: Color(0x66B4B4C8),
                ),
                filled: false,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                onChanged('');
              },
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(
                  Icons.close_rounded,
                  size: 12,
                  color: Color(0xFF7A7A92),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
