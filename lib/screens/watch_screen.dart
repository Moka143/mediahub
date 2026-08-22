import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../widgets/common/mediahub_confirm_dialog.dart';
import '../models/local_media_file.dart';
import '../models/watch_progress.dart';
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/library_actions.dart';
import '../utils/feedback_utils.dart';
import '../utils/platform_utils.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/library/library.dart';
import 'video_player_screen.dart';

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
    // The raw scanner stream, preferred over localMediaFilesProvider so a
    // refresh doesn't drop the whole library into its loading state. Note it
    // carries NO watch progress — the join happens downstream in
    // localMediaFilesProvider — so this list is only ever counted and
    // emptiness-checked here. Anything that renders a card must come from
    // the derived providers below, which are joined.
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

    final hasFilteredResults =
        filteredData.continueWatching.isNotEmpty ||
        filteredData.recentDownloads.isNotEmpty ||
        filteredData.movies.isNotEmpty ||
        filteredData.shows.isNotEmpty;

    return RefreshIndicator(
      onRefresh: _handleRefresh,
      child: CustomScrollView(
        slivers: [
          // The search field sits ABOVE the state branch deliberately.
          //
          // It used to live inside the content arm, and the branch below
          // collapses the entire sliver list to a single SliverFillRemaining
          // for loading / error / empty. Any flip into one of those while the
          // user was typing unmounted the field — losing keyboard focus and
          // the caret mid-word. Keeping it mounted whenever there is
          // something to search, or a query already in flight, removes that
          // whole class of failure rather than trying to avoid the flip.
          if (hasQuery || (localFilesAsync.value ?? []).isNotEmpty) ...[
            const SliverToBoxAdapter(
              key: ValueKey('mh-library-search-lead'),
              child: SizedBox(height: AppSpacing.sm),
            ),
            SliverToBoxAdapter(
              key: const ValueKey('mh-library-search'),
              child: LibrarySearchBar(
                controller: _searchController,
                hasQuery: hasQuery,
                onClear: () => _searchController.clear(),
                onRefresh: _refreshFromButton,
              ),
            ),
            const SliverToBoxAdapter(
              key: ValueKey('mh-library-search-gap'),
              child: SizedBox(height: AppSpacing.md),
            ),
          ],

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
              child: WatchScreenEmptyState(
                onDiscoverShows: _navigateToDiscover,
                onRescan: _handleRefresh,
              ),
            )
          // Content
          else ...[
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
                  child: LibraryHub(
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
                    onMarkWatched: _markWatched,
                    onMarkNotWatched: _markNotWatched,
                    onDeleteFile: _confirmAndDeleteFile,
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
    // (watched-only entries are preserved so the user keeps history).
    await ref.read(watchProgressProvider.notifier).cleanupStaleEntries();
    // Bidirectional reconcile: pull TMDB-rated → local + push local-watched
    // → TMDB. Additive both ways; doesn't delete server state based on
    // local absence (other devices may have watched it).
    await reconcileWatchedWithTmdb(ref);
  }

  /// Same as [_handleRefresh] but surfaces a confirmation snackbar — wired
  /// to the explicit refresh button. The pull-to-refresh path already has
  /// its own spinner affordance so it doesn't need the toast.
  Future<void> _refreshFromButton() async {
    await _handleRefresh();
    if (!mounted) return;
    AppSnackBar.showInfo(context, message: 'Library refreshed');
  }

  void _navigateToDiscover() {
    // Tab indices in MainNavigationScreen: 0 Home, 1 Downloads, 2 Shows,
    // 3 Movies, 4 Watch, 5 Calendar, 6 Favorites. The empty-library CTA
    // says "Discover Shows" so jump to Shows.
    ref.read(currentTabIndexProvider.notifier).set(2);
  }

  void _playFile(LocalMediaFile file) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => VideoPlayerScreen(file: file)),
    );
  }

  void _playFromProgress(WatchProgress progress) {
    final files = ref.read(localMediaFilesProvider).value ?? [];
    final file = files.firstWhere(
      (f) => f.path == progress.filePath,
      orElse: () => LocalMediaFile(
        path: progress.filePath,
        fileName: basenameOf(progress.filePath),
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
        builder: (context) =>
            VideoPlayerScreen(file: file, startPosition: progress.position),
      ),
    );
  }

  Future<void> _showRemoveProgressDialog(WatchProgress progress) async {
    final confirmed = await MediaHubConfirmDialog.show(
      context: context,
      title: 'Remove from Continue Watching?',
      message:
          'Remove "${progress.displayTitle}" from your continue watching list?',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    ref.read(watchProgressProvider.notifier).clearProgress(progress.filePath);
    AppSnackBar.showInfo(context, message: 'Removed from Continue Watching');
  }

  Future<void> _markWatched(LocalMediaFile file) async {
    await markAsWatched(ref, file, tmdbShowId: file.showId);
    if (!mounted) return;
    AppSnackBar.showInfo(
      context,
      message: 'Marked "${file.displayTitle}" as watched',
    );
  }

  Future<void> _markNotWatched(LocalMediaFile file) async {
    await markAsNotWatched(ref, file);
    if (!mounted) return;
    AppSnackBar.showInfo(
      context,
      message: 'Marked "${file.displayTitle}" as not watched',
    );
  }

  Future<void> _confirmAndDeleteFile(LocalMediaFile file) async {
    final confirmed = await MediaHubConfirmDialog.show(
      context: context,
      title: 'Delete file?',
      message:
          'This deletes "${file.displayTitle}" from disk. '
          'If it was downloaded via the app, the torrent will also be removed.',
      confirmLabel: 'Delete',
      destructive: true,
      icon: Icons.delete_outline,
    );
    if (confirmed != true) return;

    final result = await deleteLibraryItem(ref, file);
    if (!mounted) return;
    if (result.success) {
      AppSnackBar.showInfo(
        context,
        message: result.torrentRemoved
            ? 'Deleted file and torrent'
            : 'Deleted file',
      );
    } else {
      AppSnackBar.showError(
        context,
        message: 'Delete failed: ${result.error ?? "unknown error"}',
      );
    }
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
