import 'package:flutter/material.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../common/empty_state.dart';
import 'library_chrome.dart';
import 'library_grids.dart';
import 'library_widgets.dart';

class LibrarySectionContent extends StatelessWidget {
  final LibrarySection selectedSection;
  final ValueChanged<LibrarySection> onSectionChanged;
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

  const LibrarySectionContent({
    super.key,
    required this.selectedSection,
    required this.onSectionChanged,
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
    final theme = Theme.of(context);
    final appColors = context.appColors;

    switch (selectedSection) {
      case LibrarySection.continueWatching:
        return FocusedSection(
          label: 'Continue Watching',
          icon: Icons.play_circle_outline_rounded,
          count: continueWatching.length,
          accent: appColors.info,
          isEmpty: continueWatching.isEmpty,
          emptyIcon: Icons.play_circle_outline_rounded,
          emptyTitle: hasQuery
              ? 'No matches in Continue Watching'
              : 'Nothing to continue yet',
          emptySubtitle: hasQuery
              ? 'Try another title'
              : 'Resume watching to see items here',
          body: ContinueWatchingStrip(
            items: continueWatching,
            onTap: onPlayProgress,
            onRemove: onRemoveProgress,
            onMarkWatched: onMarkWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.recent:
        return FocusedSection(
          label: 'Recently Downloaded',
          icon: Icons.download_done_rounded,
          count: recentDownloads.length,
          accent: appColors.success,
          isEmpty: recentDownloads.isEmpty,
          emptyIcon: Icons.download_for_offline_outlined,
          emptyTitle: hasQuery ? 'No recent matches' : 'No recent downloads',
          emptySubtitle: hasQuery
              ? 'Try another search'
              : 'New downloads will appear here',
          body: LocalMediaGrid(
            files: recentDownloads,
            onTap: onPlayFile,
            onMarkWatched: onMarkWatched,
            onMarkNotWatched: onMarkNotWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.movies:
        return FocusedSection(
          label: 'Movies',
          icon: Icons.movie_rounded,
          count: movies.length,
          accent: theme.colorScheme.tertiary,
          isEmpty: movies.isEmpty,
          emptyIcon: Icons.movie_outlined,
          emptyTitle: hasQuery ? 'No matching movies' : 'No movies in library',
          emptySubtitle: hasQuery
              ? 'Try another search'
              : 'Movies will appear when downloads finish',
          body: LocalMediaGrid(
            files: movies,
            onTap: onPlayFile,
            onMarkWatched: onMarkWatched,
            onMarkNotWatched: onMarkNotWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.shows:
        return FocusedSection(
          label: 'Browse by Show',
          icon: Icons.video_library_rounded,
          count: shows.length,
          accent: appColors.warning,
          isEmpty: shows.isEmpty,
          emptyIcon: Icons.video_library_outlined,
          emptyTitle: hasQuery ? 'No matching shows' : 'No shows in library',
          emptySubtitle: hasQuery
              ? 'Try another search'
              : 'Shows will appear when downloads finish',
          body: ShowsGrid(
            shows: shows,
            onFileTap: onPlayFile,
            onMarkWatched: onMarkWatched,
            onMarkNotWatched: onMarkNotWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.all:
        return AllSectionsView(
          continueWatching: continueWatching,
          recentDownloads: recentDownloads,
          movies: movies,
          shows: shows,
          hasQuery: hasQuery,
          onSectionChanged: onSectionChanged,
          onPlayFile: onPlayFile,
          onPlayProgress: onPlayProgress,
          onRemoveProgress: onRemoveProgress,
          onMarkWatched: onMarkWatched,
          onMarkNotWatched: onMarkNotWatched,
          onDeleteFile: onDeleteFile,
        );
    }
  }
}

// ============================================================================
// Section Components
// ============================================================================

class SectionTag extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;
  final Color accent;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SectionTag({
    super.key,
    required this.label,
    required this.icon,
    required this.count,
    required this.accent,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        CountPill(count: count, accent: accent, isSelected: true),
        if (onAction != null) ...[
          const SizedBox(width: AppSpacing.sm),
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: accent,
            ),
            child: Text(
              actionLabel ?? 'View all',
              style: theme.textTheme.labelMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class FocusedSection extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;
  final Color accent;
  final bool isEmpty;
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;
  final Widget body;

  const FocusedSection({
    super.key,
    required this.label,
    required this.icon,
    required this.count,
    required this.accent,
    required this.isEmpty,
    required this.emptyIcon,
    required this.emptyTitle,
    this.emptySubtitle,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    if (isEmpty) {
      return EmptyState(
        icon: emptyIcon,
        title: emptyTitle,
        subtitle: emptySubtitle,
        compact: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTag(label: label, icon: icon, count: count, accent: accent),
        const SizedBox(height: AppSpacing.sm),
        body,
      ],
    );
  }
}

// ============================================================================
// Content Lists
// ============================================================================

class AllSectionsView extends StatelessWidget {
  final List<WatchProgress> continueWatching;
  final List<LocalMediaFile> recentDownloads;
  final List<LocalMediaFile> movies;
  final List<ShowWithSeasons> shows;
  final bool hasQuery;
  final ValueChanged<LibrarySection> onSectionChanged;
  final void Function(LocalMediaFile) onPlayFile;
  final void Function(WatchProgress) onPlayProgress;
  final void Function(WatchProgress) onRemoveProgress;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDeleteFile;

  const AllSectionsView({
    super.key,
    required this.continueWatching,
    required this.recentDownloads,
    required this.movies,
    required this.shows,
    required this.hasQuery,
    required this.onSectionChanged,
    required this.onPlayFile,
    required this.onPlayProgress,
    required this.onRemoveProgress,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDeleteFile,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final recentPreview = recentDownloads.take(5).toList();
    final moviesPreview = movies.take(5).toList();
    final showsPreview = shows.take(4).toList();
    final sections = <Widget>[];

    if (continueWatching.isNotEmpty) {
      sections.addAll([
        SectionTag(
          label: 'Continue Watching',
          icon: Icons.play_circle_outline_rounded,
          count: continueWatching.length,
          accent: appColors.info,
        ),
        const SizedBox(height: AppSpacing.sm),
        ContinueWatchingStrip(
          items: continueWatching,
          onTap: onPlayProgress,
          onRemove: onRemoveProgress,
          onMarkWatched: onMarkWatched,
          onDelete: onDeleteFile,
        ),
        const SizedBox(height: AppSpacing.md),
      ]);
    }

    if (recentDownloads.isNotEmpty) {
      sections.addAll([
        SectionTag(
          label: 'Recently Downloaded',
          icon: Icons.download_done_rounded,
          count: recentDownloads.length,
          accent: appColors.success,
          actionLabel: recentDownloads.length > recentPreview.length
              ? 'View all'
              : null,
          onAction: recentDownloads.length > recentPreview.length
              ? () => onSectionChanged(LibrarySection.recent)
              : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        LocalMediaGrid(
          files: recentPreview,
          onTap: onPlayFile,
          onMarkWatched: onMarkWatched,
          onMarkNotWatched: onMarkNotWatched,
          onDelete: onDeleteFile,
        ),
        const SizedBox(height: AppSpacing.md),
      ]);
    }

    if (movies.isNotEmpty) {
      sections.addAll([
        SectionTag(
          label: 'Movies',
          icon: Icons.movie_rounded,
          count: movies.length,
          accent: theme.colorScheme.tertiary,
          actionLabel: movies.length > moviesPreview.length ? 'View all' : null,
          onAction: movies.length > moviesPreview.length
              ? () => onSectionChanged(LibrarySection.movies)
              : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        LocalMediaGrid(
          files: moviesPreview,
          onTap: onPlayFile,
          onMarkWatched: onMarkWatched,
          onMarkNotWatched: onMarkNotWatched,
          onDelete: onDeleteFile,
        ),
        const SizedBox(height: AppSpacing.md),
      ]);
    }

    if (shows.isNotEmpty) {
      sections.addAll([
        SectionTag(
          label: 'Browse by Show',
          icon: Icons.video_library_rounded,
          count: shows.length,
          accent: appColors.warning,
          actionLabel: shows.length > showsPreview.length ? 'View all' : null,
          onAction: shows.length > showsPreview.length
              ? () => onSectionChanged(LibrarySection.shows)
              : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        ShowsGrid(
          shows: showsPreview,
          onFileTap: onPlayFile,
          onMarkWatched: onMarkWatched,
          onMarkNotWatched: onMarkNotWatched,
          onDelete: onDeleteFile,
        ),
        const SizedBox(height: AppSpacing.md),
      ]);
    }

    if (sections.isEmpty) {
      return EmptyState(
        icon: Icons.movie_filter_outlined,
        title: hasQuery ? 'No matches found' : 'Nothing in your library yet',
        subtitle: hasQuery
            ? 'Try a different search'
            : 'Download something to get started',
        compact: true,
      );
    }

    // Remove trailing spacing
    if (sections.isNotEmpty) {
      sections.removeLast();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }
}
