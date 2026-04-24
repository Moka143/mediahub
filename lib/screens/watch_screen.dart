import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../models/watch_progress.dart';
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/media/media.dart';
import 'video_player_screen.dart';

// ============================================================================
// Library Section Enum
// ============================================================================

enum LibrarySection {
  all,
  continueWatching,
  recent,
  movies,
  shows,
}

// ============================================================================
// Main Screen
// ============================================================================

/// Screen for displaying available local media files for watching
class WatchScreen extends ConsumerStatefulWidget {
  const WatchScreen({super.key});

  @override
  ConsumerState<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends ConsumerState<WatchScreen> {
  late final TextEditingController _searchController;
  String _query = '';
  LibrarySection _selectedSection = LibrarySection.all;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final next = _searchController.text;
    if (next != _query) {
      setState(() => _query = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localFilesStream = ref.watch(localMediaStreamProvider);
    final localFilesAsync = localFilesStream.hasValue
        ? AsyncValue.data(localFilesStream.value!)
        : ref.watch(localMediaFilesProvider);
    final continueWatching = ref.watch(continueWatchingProvider);
    final recentDownloads = ref.watch(recentDownloadsProvider);
    final groupedByShowAndSeason = ref.watch(localMediaByShowAndSeasonProvider);
    final localMovies = ref.watch(localMoviesProvider);

    final query = _query.trim().toLowerCase();
    final hasQuery = query.isNotEmpty;

    // Filter data based on search query
    final filteredData = _filterData(
      query: query,
      continueWatching: continueWatching,
      recentDownloads: recentDownloads,
      movies: localMovies,
      shows: groupedByShowAndSeason,
      allFiles: localFilesAsync.value ?? [],
    );

    final hasFilteredResults = filteredData.continueWatching.isNotEmpty ||
        filteredData.recentDownloads.isNotEmpty ||
        filteredData.movies.isNotEmpty ||
        filteredData.shows.isNotEmpty;

    return RefreshIndicator(
      onRefresh: _handleRefresh,
      child: CustomScrollView(
        slivers: [
          // Loading state
          if (localFilesAsync.isLoading)
            const SliverFillRemaining(
              child: LoadingIndicator(message: 'Scanning for videos...'),
            )
          // Error state
          else if (localFilesAsync.hasError)
            SliverFillRemaining(
              child: EmptyState.error(
                message: localFilesAsync.error.toString(),
                onRetry: _handleRefresh,
              ),
            )
          // Empty state
          else if ((localFilesAsync.value ?? []).isEmpty)
            SliverFillRemaining(
              child: _WatchScreenEmptyState(
                onDiscoverShows: _navigateToDiscover,
                onRescan: _handleRefresh,
              ),
            )
          // Content
          else ...[
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.sm)),

            // Search bar
            SliverToBoxAdapter(
              child: _LibrarySearchBar(
                controller: _searchController,
                hasQuery: hasQuery,
                onClear: () => _searchController.clear(),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),

            // No results state
            if (hasQuery && !hasFilteredResults)
              SliverFillRemaining(
                child: EmptyState.noResults(
                  title: 'No matches for "$_query"',
                  subtitle: 'Try a different name',
                  action: FilledButton.icon(
                    onPressed: () => _searchController.clear(),
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Clear Search'),
                  ),
                ),
              )
            else ...[
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.screenPadding,
                ),
                sliver: SliverToBoxAdapter(
                  child: _LibraryHub(
                    selectedSection: _selectedSection,
                    onSectionChanged: (section) =>
                        setState(() => _selectedSection = section),
                    allCount: filteredData.allCount,
                    continueWatching: filteredData.continueWatching,
                    recentDownloads: filteredData.recentDownloads,
                    movies: filteredData.movies,
                    shows: filteredData.shows,
                    hasQuery: hasQuery,
                    onPlayFile: _playFile,
                    onPlayProgress: _playFromProgress,
                    onRemoveProgress: _showRemoveProgressDialog,
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
            ],
          ],
        ],
      ),
    );
  }

  _FilteredData _filterData({
    required String query,
    required List<WatchProgress> continueWatching,
    required List<LocalMediaFile> recentDownloads,
    required List<LocalMediaFile> movies,
    required List<ShowWithSeasons> shows,
    required List<LocalMediaFile> allFiles,
  }) {
    if (query.isEmpty) {
      return _FilteredData(
        continueWatching: continueWatching,
        recentDownloads: recentDownloads,
        movies: movies,
        shows: shows,
        allCount: allFiles.length,
      );
    }

    return _FilteredData(
      continueWatching: continueWatching
          .where((p) => p.displayTitle.toLowerCase().contains(query))
          .toList(),
      recentDownloads: recentDownloads
          .where((f) => f.displayTitle.toLowerCase().contains(query))
          .toList(),
      movies: movies
          .where((f) => f.displayTitle.toLowerCase().contains(query))
          .toList(),
      shows: shows
          .where((s) => s.showName.toLowerCase().contains(query))
          .toList(),
      allCount: allFiles
          .where((file) => file.displayTitle.toLowerCase().contains(query))
          .length,
    );
  }

  Future<void> _handleRefresh() async {
    ref.invalidate(localMediaStreamProvider);
    ref.invalidate(localMediaScannerProvider);
    ref.invalidate(localMediaFilesProvider);
    await ref.read(localMediaFilesProvider.future);
    // Clean up watch progress entries for files that no longer exist
    await ref.read(watchProgressProvider.notifier).cleanupStaleEntries();
  }

  void _navigateToDiscover() {
    ref.read(currentTabIndexProvider.notifier).set(1);
  }

  void _playFile(LocalMediaFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(file: file),
      ),
    );
  }

  void _playFromProgress(WatchProgress progress) {
    final files = ref.read(localMediaFilesProvider).value ?? [];
    final file = files.firstWhere(
      (f) => f.path == progress.filePath,
      orElse: () => LocalMediaFile(
        path: progress.filePath,
        fileName: progress.filePath.split('/').last,
        sizeBytes: 0,
        modifiedDate: DateTime.now(),
        extension: progress.filePath.split('.').last,
        showName: progress.showName,
        seasonNumber: progress.seasonNumber,
        episodeNumber: progress.episodeNumber,
        progress: progress,
      ),
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(
          file: file,
          startPosition: progress.position,
        ),
      ),
    );
  }

  void _showRemoveProgressDialog(WatchProgress progress) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from Continue Watching?'),
        content: Text(
          'Remove "${progress.displayTitle}" from your continue watching list?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(watchProgressProvider.notifier)
                  .clearProgress(progress.filePath);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Removed from Continue Watching')),
              );
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// Filtered Data Model
// ============================================================================

class _FilteredData {
  final List<WatchProgress> continueWatching;
  final List<LocalMediaFile> recentDownloads;
  final List<LocalMediaFile> movies;
  final List<ShowWithSeasons> shows;
  final int allCount;

  const _FilteredData({
    required this.continueWatching,
    required this.recentDownloads,
    required this.movies,
    required this.shows,
    required this.allCount,
  });
}

// ============================================================================
// Search Bar Widget
// ============================================================================

class _LibrarySearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool hasQuery;
  final VoidCallback onClear;

  const _LibrarySearchBar({
    required this.controller,
    required this.hasQuery,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screenPadding),
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
          fillColor:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
    );
  }
}

// ============================================================================
// Empty State Widget
// ============================================================================

class _WatchScreenEmptyState extends StatelessWidget {
  final VoidCallback onDiscoverShows;
  final VoidCallback onRescan;

  const _WatchScreenEmptyState({
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
                    theme.colorScheme.primaryContainer
                        .withAlpha(AppOpacity.medium),
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

class _LibraryHub extends StatelessWidget {
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

  const _LibraryHub({
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
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = allCount == 0
        ? (hasQuery ? 'No matches in your library' : 'Your library is still empty')
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
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.tertiary,
              ],
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
            border: Border.all(
              color: borderColor,
              width: AppBorderWidth.thin,
            ),
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
              _CountPill(count: count, accent: foreground, isSelected: isSelected),
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
          emptySubtitle:
              hasQuery ? 'Try another title' : 'Resume watching to see items here',
          body: _ContinueWatchingStrip(
            items: continueWatching,
            onTap: onPlayProgress,
            onRemove: onRemoveProgress,
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
          emptySubtitle:
              hasQuery ? 'Try another search' : 'New downloads will appear here',
          body: _RecentDownloadsList(
            files: recentDownloads,
            onTap: onPlayFile,
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
          body: _MoviesList(movies: movies, onFileTap: onPlayFile),
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
          body: _ShowsList(shows: shows, onFileTap: onPlayFile),
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
        _SectionTag(
          label: label,
          icon: icon,
          count: count,
          accent: accent,
        ),
        const SizedBox(height: AppSpacing.sm),
        body,
      ],
    );
  }
}

// ============================================================================
// Content Lists
// ============================================================================

class _ContinueWatchingStrip extends StatelessWidget {
  final List<WatchProgress> items;
  final void Function(WatchProgress) onTap;
  final void Function(WatchProgress) onRemove;

  const _ContinueWatchingStrip({
    required this.items,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 190,
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
          );
        },
      ),
    );
  }
}

class _RecentDownloadsList extends StatelessWidget {
  final List<LocalMediaFile> files;
  final void Function(LocalMediaFile) onTap;

  const _RecentDownloadsList({
    required this.files,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: files.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final file = files[index];
        return LocalMediaListItem(
          file: file,
          onTap: () => onTap(file),
        );
      },
    );
  }
}

class _MoviesList extends StatelessWidget {
  final List<LocalMediaFile> movies;
  final void Function(LocalMediaFile) onFileTap;

  const _MoviesList({
    required this.movies,
    required this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: movies.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final file = movies[index];
        return LocalMediaListItem(
          file: file,
          onTap: () => onFileTap(file),
        );
      },
    );
  }
}

class _ShowsList extends StatelessWidget {
  final List<ShowWithSeasons> shows;
  final void Function(LocalMediaFile) onFileTap;

  const _ShowsList({
    required this.shows,
    required this.onFileTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: shows.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final showData = shows[index];
        return ShowExpansionTile(
          showData: showData,
          onFileTap: onFileTap,
        );
      },
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
          actionLabel:
              recentDownloads.length > recentPreview.length ? 'View all' : null,
          onAction: recentDownloads.length > recentPreview.length
              ? () => onSectionChanged(LibrarySection.recent)
              : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        _RecentDownloadsList(files: recentPreview, onTap: onPlayFile),
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
        _MoviesList(movies: moviesPreview, onFileTap: onPlayFile),
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
        _ShowsList(shows: showsPreview, onFileTap: onPlayFile),
        const SizedBox(height: AppSpacing.md),
      ]);
    }

    if (sections.isEmpty) {
      return EmptyState(
        icon: Icons.movie_filter_outlined,
        title: hasQuery ? 'No matches found' : 'Nothing in your library yet',
        subtitle: hasQuery ? 'Try a different search' : 'Download something to get started',
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
