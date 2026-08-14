import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_theme.dart';
import '../../design/app_tokens.dart';
import '../../models/local_media_file.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../../utils/feedback_utils.dart';
import '../common/empty_state.dart';
import '../media/media.dart';

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
          _LibraryHeader(subtitle: subtitle),
          const SizedBox(height: AppSpacing.sm),
          _LibraryChips(
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
            child: _LibrarySectionContent(
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

class _LibraryHeader extends StatelessWidget {
  final String subtitle;

  const _LibraryHeader({required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
            ),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: const Icon(
            Icons.video_library_rounded,
            size: 20,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Library Hub',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: appColors.mutedText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// Library Chips
// ============================================================================

class _LibraryChips extends StatelessWidget {
  final LibrarySection selectedSection;
  final ValueChanged<LibrarySection> onSectionChanged;
  final int allCount;
  final int continueWatchingCount;
  final int recentCount;
  final int moviesCount;
  final int showsCount;

  const _LibraryChips({
    required this.selectedSection,
    required this.onSectionChanged,
    required this.allCount,
    required this.continueWatchingCount,
    required this.recentCount,
    required this.moviesCount,
    required this.showsCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        _LibraryChip(
          section: LibrarySection.all,
          selectedSection: selectedSection,
          label: 'All',
          icon: Icons.dashboard_rounded,
          count: allCount,
          accent: theme.colorScheme.primary,
          onTap: () => onSectionChanged(LibrarySection.all),
        ),
        _LibraryChip(
          section: LibrarySection.continueWatching,
          selectedSection: selectedSection,
          label: 'Continue',
          icon: Icons.play_circle_outline_rounded,
          count: continueWatchingCount,
          accent: appColors.info,
          onTap: () => onSectionChanged(LibrarySection.continueWatching),
        ),
        _LibraryChip(
          section: LibrarySection.recent,
          selectedSection: selectedSection,
          label: 'Recent',
          icon: Icons.download_done_rounded,
          count: recentCount,
          accent: appColors.success,
          onTap: () => onSectionChanged(LibrarySection.recent),
        ),
        _LibraryChip(
          section: LibrarySection.movies,
          selectedSection: selectedSection,
          label: 'Movies',
          icon: Icons.movie_rounded,
          count: moviesCount,
          accent: theme.colorScheme.tertiary,
          onTap: () => onSectionChanged(LibrarySection.movies),
        ),
        _LibraryChip(
          section: LibrarySection.shows,
          selectedSection: selectedSection,
          label: 'Shows',
          icon: Icons.video_library_rounded,
          count: showsCount,
          accent: appColors.warning,
          onTap: () => onSectionChanged(LibrarySection.shows),
        ),
      ],
    );
  }
}

class _LibraryChip extends StatelessWidget {
  final LibrarySection section;
  final LibrarySection selectedSection;
  final String label;
  final IconData icon;
  final int count;
  final Color accent;
  final VoidCallback onTap;

  const _LibraryChip({
    required this.section,
    required this.selectedSection,
    required this.label,
    required this.icon,
    required this.count,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = selectedSection == section;
    final foreground = isSelected ? accent : theme.colorScheme.onSurfaceVariant;
    final background = isSelected
        ? accent.withValues(alpha: 0.14)
        : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final borderColor = isSelected
        ? accent
        : theme.colorScheme.outlineVariant.withValues(alpha: 0.4);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: borderColor, width: AppBorderWidth.thin),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              _CountPill(
                count: count,
                accent: foreground,
                isSelected: isSelected,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  final int count;
  final Color accent;
  final bool isSelected;

  const _CountPill({
    required this.count,
    required this.accent,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: isSelected
            ? accent.withValues(alpha: 0.22)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        count.toString(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: accent,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ============================================================================
// Library Section Content
// ============================================================================

class _LibrarySectionContent extends StatelessWidget {
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

  const _LibrarySectionContent({
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
        return _FocusedSection(
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
          body: _ContinueWatchingStrip(
            items: continueWatching,
            onTap: onPlayProgress,
            onRemove: onRemoveProgress,
            onMarkWatched: onMarkWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.recent:
        return _FocusedSection(
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
          body: _LocalMediaGrid(
            files: recentDownloads,
            onTap: onPlayFile,
            onMarkWatched: onMarkWatched,
            onMarkNotWatched: onMarkNotWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.movies:
        return _FocusedSection(
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
          body: _LocalMediaGrid(
            files: movies,
            onTap: onPlayFile,
            onMarkWatched: onMarkWatched,
            onMarkNotWatched: onMarkNotWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.shows:
        return _FocusedSection(
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
          body: _ShowsGrid(
            shows: shows,
            onFileTap: onPlayFile,
            onMarkWatched: onMarkWatched,
            onMarkNotWatched: onMarkNotWatched,
            onDelete: onDeleteFile,
          ),
        );

      case LibrarySection.all:
        return _AllSectionsView(
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

class _SectionTag extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;
  final Color accent;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _SectionTag({
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
        _CountPill(count: count, accent: accent, isSelected: true),
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

class _FocusedSection extends StatelessWidget {
  final String label;
  final IconData icon;
  final int count;
  final Color accent;
  final bool isEmpty;
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;
  final Widget body;

  const _FocusedSection({
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
        _SectionTag(label: label, icon: icon, count: count, accent: accent),
        const SizedBox(height: AppSpacing.sm),
        body,
      ],
    );
  }
}

// ============================================================================
// Content Lists
// ============================================================================

class _ContinueWatchingStrip extends ConsumerWidget {
  final List<WatchProgress> items;
  final void Function(WatchProgress) onTap;
  final void Function(WatchProgress) onRemove;
  final void Function(LocalMediaFile)? onMarkWatched;
  final void Function(LocalMediaFile)? onDelete;

  const _ContinueWatchingStrip({
    required this.items,
    required this.onTap,
    required this.onRemove,
    this.onMarkWatched,
    this.onDelete,
  });

  /// Locate the underlying [LocalMediaFile] for a Continue-Watching entry —
  /// needed because the mark-watched / delete actions operate on files, not
  /// progress records. Returns null if the file is no longer on disk.
  LocalMediaFile? _fileFor(WidgetRef ref, WatchProgress progress) {
    final files = ref.read(localMediaFilesProvider).value ?? [];
    for (final f in files) {
      if (f.path == progress.filePath) return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      // Asked of the card rather than hard-coded: these rows carry a
      // subtitle ("48 min remaining"), and the previous fixed 190 clipped
      // 84 px off every card.
      height: MediaPosterCard.heightForWidth(context),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        itemBuilder: (context, index) {
          final progress = items[index];
          return ContinueWatchingCard(
            progress: progress,
            onTap: () => onTap(progress),
            onRemove: () => onRemove(progress),
            onMarkWatched: onMarkWatched == null
                ? null
                : () {
                    final f = _fileFor(ref, progress);
                    if (f != null) {
                      onMarkWatched!(f);
                    } else {
                      AppSnackBar.showInfo(
                        context,
                        message: 'File missing on disk — rescan to clean up',
                      );
                    }
                  },
            onDelete: onDelete == null
                ? null
                : () {
                    final f = _fileFor(ref, progress);
                    if (f != null) {
                      onDelete!(f);
                    } else {
                      AppSnackBar.showInfo(
                        context,
                        message: 'File missing on disk — rescan to clean up',
                      );
                    }
                  },
          );
        },
      ),
    );
  }
}

/// Grid of [MediaPosterCard]s for flat lists of local files (Recent / Movies).
class _LocalMediaGrid extends StatelessWidget {
  final List<LocalMediaFile> files;
  final void Function(LocalMediaFile) onTap;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDelete;

  const _LocalMediaGrid({
    required this.files,
    required this.onTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        // 2:3 poster (width * 1.5) + ~45px caption block = needs ~width / 0.56.
        // Anything tighter clips the title row and triggers Flutter's striped
        // overflow indicator at the card's bottom edge.
        childAspectRatio: 152 / 272,
      ),
      itemCount: files.length,
      itemBuilder: (_, index) {
        final file = files[index];
        return _LocalMediaCard(
          file: file,
          onTap: () => onTap(file),
          onMarkWatched: () => onMarkWatched(file),
          onMarkNotWatched: () => onMarkNotWatched(file),
          onDelete: () => onDelete(file),
        );
      },
    );
  }
}

/// Grid of show cards. Tap a show → modal sheet with seasons & episodes.
class _ShowsGrid extends StatelessWidget {
  final List<ShowWithSeasons> shows;
  final void Function(LocalMediaFile) onFileTap;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDelete;

  const _ShowsGrid({
    required this.shows,
    required this.onFileTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: AppSpacing.md,
        crossAxisSpacing: AppSpacing.md,
        // 2:3 poster (width * 1.5) + ~45px caption block = needs ~width / 0.56.
        // Anything tighter clips the title row and triggers Flutter's striped
        // overflow indicator at the card's bottom edge.
        childAspectRatio: 152 / 272,
      ),
      itemCount: shows.length,
      itemBuilder: (_, index) {
        final showData = shows[index];
        return _ShowCard(
          showData: showData,
          onFileTap: onFileTap,
          onMarkWatched: onMarkWatched,
          onMarkNotWatched: onMarkNotWatched,
          onDelete: onDelete,
        );
      },
    );
  }
}

/// Single library item rendered as a poster card. Resolves its poster (show
/// poster if it's an episode, movie poster otherwise) via the existing
/// TMDB poster providers.
class _LocalMediaCard extends ConsumerWidget {
  final LocalMediaFile file;
  final VoidCallback onTap;
  final VoidCallback onMarkWatched;
  final VoidCallback onMarkNotWatched;
  final VoidCallback onDelete;

  const _LocalMediaCard({
    required this.file,
    required this.onTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  AsyncValue<String?>? _resolvePoster(WidgetRef ref) {
    if (file.showName != null &&
        file.showName!.isNotEmpty &&
        (file.seasonNumber != null || file.episodeNumber != null)) {
      return ref.watch(showPosterProvider(file.showName!));
    }
    // For movies, strip quality/year/extension noise before searching TMDB —
    // a raw filename like `Movie.2020.1080p.BluRay.mkv` rarely matches.
    final movieName = file.showName ?? _cleanMovieName(file.fileName);
    if (movieName.isEmpty) return null;
    return ref.watch(moviePosterProvider(movieName));
  }

  /// Best-effort: convert a torrent-style filename into something searchable.
  /// Drops extension, common quality tags, release-group suffixes and year.
  static String _cleanMovieName(String filename) {
    var name = filename.replaceAll(
      RegExp(r'\.(mp4|mkv|avi|mov|wmv|flv|webm|m4v)$', caseSensitive: false),
      '',
    );
    name = name.replaceAll(
      RegExp(
        r'[\.\s]?(1080p|720p|480p|2160p|4K|HDRip|BluRay|WEB-DL|WEBRip|BRRip|DVDRip|HDTV).*',
        caseSensitive: false,
      ),
      '',
    );
    name = name.replaceAll(RegExp(r'\s*\(\d{4}\)\s*'), ' ');
    name = name.replaceAll(RegExp(r'\s*\d{4}\s*$'), '');
    name = name.replaceAll(RegExp(r'[\._]'), ' ');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name;
  }

  String _displayTitle() {
    if (file.showName != null && file.showName!.isNotEmpty) {
      return file.episodeCode != null
          ? '${file.showName} ${file.episodeCode}'
          : file.showName!;
    }
    final cleaned = _cleanMovieName(file.fileName);
    return cleaned.isNotEmpty ? cleaned : file.fileName;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = <MediaCardAction>[
      if (!file.isWatched)
        MediaCardAction(
          icon: Icons.check_circle_outline_rounded,
          label: 'Mark as watched',
          onSelected: onMarkWatched,
        ),
      if (file.isWatched)
        MediaCardAction(
          icon: Icons.remove_circle_outline_rounded,
          label: 'Mark as not watched',
          onSelected: onMarkNotWatched,
        ),
      MediaCardAction(
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        onSelected: onDelete,
        destructive: true,
      ),
    ];

    return MediaPosterCard(
      posterAsync: _resolvePoster(ref),
      title: _displayTitle(),
      subtitle: [
        file.formattedSize,
        if (file.quality != null) file.quality!,
      ].join(' • '),
      badge: file.episodeCode,
      progress: file.hasProgress ? file.watchProgress : null,
      isWatched: file.isWatched,
      onTap: onTap,
      actions: actions,
    );
  }
}

/// Show-level card. Tap opens [ShowEpisodesSheet] for season/episode drill-in.
class _ShowCard extends ConsumerWidget {
  final ShowWithSeasons showData;
  final void Function(LocalMediaFile) onFileTap;
  final void Function(LocalMediaFile) onMarkWatched;
  final void Function(LocalMediaFile) onMarkNotWatched;
  final void Function(LocalMediaFile) onDelete;

  const _ShowCard({
    required this.showData,
    required this.onFileTap,
    required this.onMarkWatched,
    required this.onMarkNotWatched,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posterAsync = ref.watch(showPosterProvider(showData.showName));
    final hasMultipleSeasons = showData.seasons.length > 1;
    final subtitle = hasMultipleSeasons
        ? '${showData.seasons.length} seasons • ${showData.totalEpisodes} ep'
        : '${showData.totalEpisodes} episode'
              '${showData.totalEpisodes > 1 ? 's' : ''}';

    return MediaPosterCard(
      posterAsync: posterAsync,
      title: showData.showName,
      subtitle: subtitle,
      onTap: () => ShowEpisodesSheet.show(
        context,
        showData: showData,
        onFileTap: (f) {
          Navigator.of(context).maybePop();
          onFileTap(f);
        },
        onMarkWatched: onMarkWatched,
        onMarkNotWatched: onMarkNotWatched,
        onDelete: onDelete,
      ),
    );
  }
}

// ============================================================================
// All Sections View
// ============================================================================

class _AllSectionsView extends StatelessWidget {
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

  const _AllSectionsView({
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
        _SectionTag(
          label: 'Continue Watching',
          icon: Icons.play_circle_outline_rounded,
          count: continueWatching.length,
          accent: appColors.info,
        ),
        const SizedBox(height: AppSpacing.sm),
        _ContinueWatchingStrip(
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
        _SectionTag(
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
        _LocalMediaGrid(
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
        _SectionTag(
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
        _LocalMediaGrid(
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
        _SectionTag(
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
        _ShowsGrid(
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
