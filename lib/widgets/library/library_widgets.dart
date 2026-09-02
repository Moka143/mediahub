import 'package:flutter/material.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import 'library_chrome.dart';
import 'library_sections.dart';

enum LibrarySection { all, continueWatching, recent, movies, shows }

// ============================================================================
// Search Bar Widget
// ============================================================================

class LibrarySearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool hasQuery;
  final VoidCallback onClear;
  final VoidCallback onRefresh;

  const LibrarySearchBar({
    super.key,
    required this.controller,
    required this.hasQuery,
    required this.onClear,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: 'Search your library',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: hasQuery
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Clear search',
                        onPressed: onClear,
                      )
                    : null,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // Explicit refresh affordance — pull-to-refresh isn't an obvious
          // gesture on desktop, so users were left thinking the library
          // wouldn't pick up out-of-band file changes.
          IconButton.filledTonal(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh library',
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Empty State Widget
// ============================================================================

class WatchScreenEmptyState extends StatelessWidget {
  final VoidCallback onDiscoverShows;
  final VoidCallback onRescan;

  const WatchScreenEmptyState({
    super.key,
    required this.onDiscoverShows,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icon with gradient background
            Container(
              padding: const EdgeInsets.all(AppSpacing.xl),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primaryContainer,
                    theme.colorScheme.primaryContainer.withAlpha(
                      AppOpacity.medium,
                    ),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.video_library_outlined,
                size: 64,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Your Library is Empty',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Downloaded shows and movies will appear here.\nStart by discovering what to watch!',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: appColors.mutedText,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.xxl),
            FilledButton.icon(
              onPressed: onDiscoverShows,
              icon: const Icon(Icons.explore_rounded),
              label: const Text('Discover Shows'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.md,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextButton.icon(
              onPressed: onRescan,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Rescan Downloads Folder'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Library Hub Widget
// ============================================================================

class LibraryHub extends StatelessWidget {
  final LibrarySection selectedSection;
  final ValueChanged<LibrarySection> onSectionChanged;
  final int allCount;
  final List<WatchProgress> continueWatching;
  final List<LocalMediaFile> recentDownloads;
  final List<LocalMediaFile> movies;
  final List<ShowWithSeasons> shows;
  final bool hasQuery;
  final void Function(LocalMediaFile) onPlayFile;
  final void Function(WatchProgress) onPlayProgress;
  final void Function(WatchProgress) onRemoveProgress;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDeleteFile;

  const LibraryHub({
    super.key,
    required this.selectedSection,
    required this.onSectionChanged,
    required this.allCount,
    required this.continueWatching,
    required this.recentDownloads,
    required this.movies,
    required this.shows,
    required this.hasQuery,
    required this.onPlayFile,
    required this.onPlayProgress,
    required this.onRemoveProgress,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDeleteFile,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = allCount == 0
        ? (hasQuery
              ? 'No matches in your library'
              : 'Your library is still empty')
        : '$allCount items • Tap a tag to focus a section';

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LibraryHeader(subtitle: subtitle),
          const SizedBox(height: AppSpacing.sm),
          LibraryChips(
            selectedSection: selectedSection,
            onSectionChanged: onSectionChanged,
            allCount: allCount,
            continueWatchingCount: continueWatching.length,
            recentCount: recentDownloads.length,
            moviesCount: movies.length,
            showsCount: shows.length,
          ),
          const SizedBox(height: AppSpacing.md),
          AnimatedSwitcher(
            duration: AppDuration.normal,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: LibrarySectionContent(
              key: ValueKey(selectedSection),
              selectedSection: selectedSection,
              onSectionChanged: onSectionChanged,
              continueWatching: continueWatching,
              recentDownloads: recentDownloads,
              movies: movies,
              shows: shows,
              hasQuery: hasQuery,
              onPlayFile: onPlayFile,
              onPlayProgress: onPlayProgress,
              onRemoveProgress: onRemoveProgress,
              onMarkWatched: onMarkWatched,
              onMarkNotWatched: onMarkNotWatched,
              onDeleteFile: onDeleteFile,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Library Header
// ============================================================================
