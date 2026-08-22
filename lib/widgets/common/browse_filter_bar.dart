import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import 'browse_search_pill.dart';
import 'mediahub_chip.dart';

/// Shared filter row used by the Movies and TV Shows browse screens.
///
/// Layout:
///   * Wide (≥ 720px): single row — chips · sort · search pill (220px).
///   * Narrow (< 720px): two rows — chips · (sort + search).
///
/// Each screen keeps its own typed sort picker; pass it via [sortPicker].
class BrowseFilterBar extends StatefulWidget {
  const BrowseFilterBar({
    super.key,
    required this.genres,
    required this.selectedGenre,
    required this.onGenreSelected,
    required this.sortPicker,
    required this.searchController,
    required this.onSearchChanged,
    required this.searchActive,
    required this.searchHint,
  });

  final List<String> genres;
  final String selectedGenre;
  final ValueChanged<String> onGenreSelected;

  /// Caller-provided sort picker — kept opaque so each screen can use
  /// its own typed enum / popup without leaking generics here.
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
  /// the narrow layout nests it in an `Expanded` inside a `Column`, the wide
  /// one puts it directly in a `Row`. A local key cannot match across that,
  /// so resizing the window past 720px while typing rebuilt the field from
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

          final chips = AnimatedOpacity(
            duration: AppDuration.fast,
            opacity: widget.searchActive ? 0.4 : 1.0,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final g in widget.genres) ...[
                    MediaHubFilterChip(
                      label: g,
                      selected: g == widget.selectedGenre,
                      onTap: widget.searchActive
                          ? null
                          : () => widget.onGenreSelected(g),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                ],
              ),
            ),
          );

          final sort = AnimatedOpacity(
            duration: AppDuration.fast,
            opacity: widget.searchActive ? 0.4 : 1.0,
            child: widget.sortPicker,
          );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                chips,
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    sort,
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: BrowseSearchPill(
                        key: _searchKey,
                        controller: widget.searchController,
                        onChanged: widget.onSearchChanged,
                        hint: widget.searchHint,
                        width: null,
                      ),
                    ),
                  ],
                ),
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: chips),
              const SizedBox(width: AppSpacing.md),
              sort,
              const SizedBox(width: AppSpacing.md),
              BrowseSearchPill(
                key: _searchKey,
                controller: widget.searchController,
                onChanged: widget.onSearchChanged,
                hint: widget.searchHint,
              ),
            ],
          );
        },
      ),
    );
  }
}
