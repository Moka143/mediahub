import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../common/browse_search_pill.dart';
import '../common/empty_state.dart';
import '../editorial/editorial.dart';
import 'library_chrome.dart';
import 'library_item_actions.dart';
import 'library_section.dart';
import 'library_sections.dart';

/// Search field and rescan button above the Library.
class LibrarySearchBar extends StatelessWidget {
  const LibrarySearchBar({
    super.key,
    required this.controller,
    required this.onRefresh,
    this.refreshing = false,
  });

  final TextEditingController controller;
  final VoidCallback onRefresh;

  /// A rescan is running — the button shows it and does nothing.
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: Row(
        children: [
          Expanded(
            child: BrowseSearchPill(
              controller: controller,
              // The screen listens to the controller itself.
              onChanged: (_) {},
              hint: 'Search your library…',
              width: null,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // An explicit rescan — pull-to-refresh is not an obvious gesture
          // on desktop, and files can change behind the app's back.
          refreshing
              ? const SizedBox(
                  width: 32,
                  height: 32,
                  child: Padding(
                    padding: EdgeInsets.all(AppSpacing.sm),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.fg1,
                    ),
                  ),
                )
              : EditorialIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Rescan library',
                  onPressed: onRefresh,
                ),
        ],
      ),
    );
  }
}

/// The Library before anything has been downloaded.
class WatchScreenEmptyState extends StatelessWidget {
  const WatchScreenEmptyState({
    super.key,
    required this.onDiscoverShows,
    required this.onRescan,
  });

  final VoidCallback onDiscoverShows;
  final VoidCallback onRescan;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.video_library_outlined,
      title: 'Your library is empty',
      subtitle:
          'Downloaded shows and movies appear here. Find something to watch '
          'in TV Shows or Movies.',
      action: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        alignment: WrapAlignment.center,
        children: [
          EditorialButton(
            label: 'Browse shows',
            icon: Icons.explore_rounded,
            kind: EditorialButtonKind.accent,
            onPressed: onDiscoverShows,
          ),
          EditorialButton(
            label: 'Rescan downloads folder',
            icon: Icons.refresh_rounded,
            kind: EditorialButtonKind.ghost,
            onPressed: onRescan,
          ),
        ],
      ),
    );
  }
}

/// The Library: title, section chips, and the selected section — all as
/// slivers, so the grids inside build only what is on screen.
class LibraryHub extends StatelessWidget {
  const LibraryHub({
    super.key,
    required this.selectedSection,
    required this.onSectionChanged,
    required this.contents,
    required this.hasQuery,
    required this.actions,
  });

  final LibrarySection selectedSection;
  final ValueChanged<LibrarySection> onSectionChanged;
  final LibraryContents contents;
  final bool hasQuery;
  final LibraryActions actions;

  @override
  Widget build(BuildContext context) {
    final count = contents.allCount;
    final subtitle = count == 0
        ? (hasQuery ? 'No matches' : 'Empty')
        : (count == 1 ? '1 file' : '$count files');

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LibraryHeader(subtitle: subtitle),
                  const SizedBox(height: AppSpacing.md),
                  LibraryChips(
                    selected: selectedSection,
                    onChanged: onSectionChanged,
                    counts: {
                      for (final s in LibrarySection.values)
                        s: contents.countOf(s),
                    },
                  ),
                ],
              ),
            ),
          ),
          ...librarySectionSlivers(
            section: selectedSection,
            contents: contents,
            hasQuery: hasQuery,
            actions: actions,
            onSectionChanged: onSectionChanged,
          ),
        ],
      ),
    );
  }
}
