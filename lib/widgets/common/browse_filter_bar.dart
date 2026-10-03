import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import 'browse_search_pill.dart';

/// Shared filter row used by the Movies and TV Shows browse screens:
/// genre · sort · search pill.
///
/// The pickers are drop-downs, so the row fits on one line at any width the
/// shell gives it. Below 720px the search pill takes the rest of the row
/// instead of its fixed 220px.
///
/// Each screen passes its own typed pickers ([genrePicker], [sortPicker]).
class BrowseFilterBar extends StatefulWidget {
  const BrowseFilterBar({
    super.key,
    required this.genrePicker,
    required this.sortPicker,
    required this.searchController,
    required this.onSearchChanged,
    required this.searchActive,
    required this.searchHint,
  });

  /// Kept opaque, like [sortPicker], so the option types don't leak here.
  final Widget genrePicker;
  final Widget sortPicker;

  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final bool searchActive;
  final String searchHint;

  @override
  State<BrowseFilterBar> createState() => _BrowseFilterBarState();
}

class _BrowseFilterBarState extends State<BrowseFilterBar> {
  /// A GlobalKey, not a ValueKey, because the pill genuinely changes parent:
  /// the narrow layout nests it in an `Expanded`, the wide one puts it
  /// directly in the `Row`. A local key cannot match across that, so
  /// resizing the window past 720px while typing rebuilt the field from
  /// scratch and dropped keyboard focus. A GlobalKey lets the element move
  /// instead of being recreated.
  final GlobalKey _searchKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: AppColors.line, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.sm,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 720;

          // Dimmed while searching: search results ignore both.
          final pickers = AnimatedOpacity(
            duration: AppDuration.fast,
            opacity: widget.searchActive ? 0.4 : 1.0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.genrePicker,
                const SizedBox(width: AppSpacing.sm),
                widget.sortPicker,
              ],
            ),
          );

          return Row(
            children: [
              pickers,
              const SizedBox(width: AppSpacing.md),
              if (isNarrow)
                Expanded(
                  child: BrowseSearchPill(
                    key: _searchKey,
                    controller: widget.searchController,
                    onChanged: widget.onSearchChanged,
                    hint: widget.searchHint,
                    width: null,
                  ),
                )
              else ...[
                const Spacer(),
                BrowseSearchPill(
                  key: _searchKey,
                  controller: widget.searchController,
                  onChanged: widget.onSearchChanged,
                  hint: widget.searchHint,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
