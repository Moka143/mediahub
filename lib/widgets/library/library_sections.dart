import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/local_media_file.dart';
import '../../models/show_with_seasons.dart';
import '../../models/watch_progress.dart';
import '../common/empty_state.dart';
import '../media/row_header.dart';
import 'library_grids.dart';
import 'library_item_actions.dart';
import 'library_section.dart';

/// What the Library shows, already narrowed by the search box.
@immutable
class LibraryContents {
  const LibraryContents({
    required this.continueWatching,
    required this.recentDownloads,
    required this.movies,
    required this.shows,
    required this.allCount,
  });

  final List<WatchProgress> continueWatching;
  final List<LocalMediaFile> recentDownloads;
  final List<LocalMediaFile> movies;
  final List<ShowWithSeasons> shows;

  /// Files in the library (matching the search, when there is one).
  final int allCount;

  int countOf(LibrarySection section) => switch (section) {
    LibrarySection.all => allCount,
    LibrarySection.continueWatching => continueWatching.length,
    LibrarySection.recent => recentDownloads.length,
    LibrarySection.movies => movies.length,
    LibrarySection.shows => shows.length,
  };

  bool get isEmpty =>
      continueWatching.isEmpty &&
      recentDownloads.isEmpty &&
      movies.isEmpty &&
      shows.isEmpty;
}

/// The slivers for [section]: a header, then that section's row or grid —
/// or, for [LibrarySection.all], a preview of each section that has
/// anything in it.
List<Widget> librarySectionSlivers({
  required LibrarySection section,
  required LibraryContents contents,
  required bool hasQuery,
  required LibraryActions actions,
  required ValueChanged<LibrarySection> onSectionChanged,
}) {
  Widget empty(LibrarySection s) => SliverToBoxAdapter(
    child: EmptyState(
      icon: s.icon,
      title: s.emptyTitle(hasQuery: hasQuery),
      subtitle: s.emptySubtitle(hasQuery: hasQuery),
      compact: true,
    ),
  );

  Widget header(LibrarySection s, {bool preview = false}) {
    final count = contents.countOf(s);
    return SliverPadding(
      padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.md),
      sliver: SliverToBoxAdapter(
        child: RowHeader(
          title: s.label,
          note: '$count',
          size: AppType.sizeTitle,
          onSeeAll: preview ? () => onSectionChanged(s) : null,
        ),
      ),
    );
  }

  List<Widget> body(LibrarySection s, {int? limit}) {
    List<T> take<T>(List<T> items) => limit == null || items.length <= limit
        ? items
        : items.sublist(0, limit);
    return switch (s) {
      LibrarySection.continueWatching => [
        SliverToBoxAdapter(
          child: ContinueWatchingStrip(
            items: contents.continueWatching,
            actions: actions,
          ),
        ),
      ],
      LibrarySection.recent => [
        LibraryFileGrid(
          files: take(contents.recentDownloads),
          actions: actions,
        ),
      ],
      LibrarySection.movies => [
        LibraryFileGrid(files: take(contents.movies), actions: actions),
      ],
      LibrarySection.shows => [
        LibraryShowGrid(shows: take(contents.shows), actions: actions),
      ],
      LibrarySection.all => const [],
    };
  }

  if (section != LibrarySection.all) {
    if (contents.countOf(section) == 0) return [empty(section)];
    return [header(section), ...body(section)];
  }

  if (contents.isEmpty) return [empty(LibrarySection.all)];

  // A preview of each section, with "See all" when it holds more than the
  // preview shows. The row of Continue Watching scrolls, so it is whole.
  const previews = {
    LibrarySection.continueWatching: null,
    LibrarySection.recent: 5,
    LibrarySection.movies: 5,
    LibrarySection.shows: 4,
  };
  return [
    for (final entry in previews.entries)
      if (contents.countOf(entry.key) > 0) ...[
        header(
          entry.key,
          preview:
              entry.value != null && contents.countOf(entry.key) > entry.value!,
        ),
        ...body(entry.key, limit: entry.value),
      ],
  ];
}
