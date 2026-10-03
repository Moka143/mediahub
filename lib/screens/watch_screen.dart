import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../models/show_with_seasons.dart';
import '../models/watch_progress.dart';
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../services/library_actions.dart';
import '../utils/error_messages.dart';
import '../utils/feedback_utils.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/library/library.dart';
import '../widgets/media/poster_lookup.dart';
import 'settings_screen.dart';

/// The Library: everything already on disk, plus what is half-watched.
class WatchScreen extends ConsumerStatefulWidget {
  const WatchScreen({super.key});

  @override
  ConsumerState<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends ConsumerState<WatchScreen> {
  late final TextEditingController _searchController;
  String _query = '';
  LibrarySection _selectedSection = LibrarySection.all;
  bool _rescanning = false;

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
    if (next != _query) setState(() => _query = next);
  }

  @override
  Widget build(BuildContext context) {
    // The raw scanner stream, preferred over localMediaFilesProvider so a
    // rescan doesn't drop the whole library into its loading state. It
    // carries NO watch progress — the join happens downstream — so it is
    // only counted and emptiness-checked here; anything that renders a card
    // comes from the joined providers below.
    final localFilesStream = ref.watch(localMediaStreamProvider);
    final localFilesAsync = localFilesStream.hasValue
        ? AsyncValue.data(localFilesStream.value!)
        : ref.watch(localMediaFilesProvider);
    final allFiles = localFilesAsync.value ?? const <LocalMediaFile>[];

    final query = _query.trim().toLowerCase();
    final hasQuery = query.isNotEmpty;
    final contents = _filter(
      query: query,
      continueWatching: ref.watch(continueWatchingProvider),
      recentDownloads: ref.watch(recentDownloadsProvider),
      movies: ref.watch(localMoviesProvider),
      shows: ref.watch(localMediaByShowAndSeasonProvider),
      allFiles: allFiles,
    );

    return RefreshIndicator(
      onRefresh: _pullToRefresh,
      child: CustomScrollView(
        slivers: [
          // The search field sits ABOVE the state branch deliberately: the
          // branch below collapses everything to one SliverFillRemaining for
          // loading / error / empty, and a flip into one of those while the
          // user was typing unmounted the field — focus and caret lost
          // mid-word. Keeping it mounted whenever there is something to
          // search, or a query in flight, removes that class of failure.
          if (hasQuery || allFiles.isNotEmpty) ...[
            const SliverToBoxAdapter(
              key: ValueKey('mh-library-search-lead'),
              child: SizedBox(height: AppSpacing.md),
            ),
            SliverToBoxAdapter(
              key: const ValueKey('mh-library-search'),
              child: LibrarySearchBar(
                controller: _searchController,
                refreshing: _rescanning,
                onRefresh: () => unawaited(_rescanFromButton()),
              ),
            ),
          ],
          if (localFilesAsync.isLoading && !localFilesAsync.hasValue)
            const SliverFillRemaining(
              child: LoadingIndicator(
                message: 'Scanning your downloads folder…',
              ),
            )
          else if (localFilesAsync.hasError && !localFilesAsync.hasValue)
            SliverFillRemaining(
              child: EmptyState.error(
                title: "Couldn't read your library",
                message: friendlyErrorMessage(
                  localFilesAsync.error!,
                  subject: 'your downloads folder',
                ),
                onRetry: () => unawaited(_rescanFromButton()),
                secondaryLabel: 'Open Settings',
                onSecondary: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ),
            )
          else if (allFiles.isEmpty)
            SliverFillRemaining(
              child: WatchScreenEmptyState(
                onDiscoverShows: () => ref
                    .read(currentTabIndexProvider.notifier)
                    .show(AppTab.shows),
                onRescan: () => unawaited(_rescanFromButton()),
              ),
            )
          else if (hasQuery && contents.isEmpty)
            SliverFillRemaining(
              child: EmptyState.noResults(
                title: 'Nothing matches "$_query"',
                subtitle: 'Try a different name.',
                action: TextButton(
                  onPressed: _searchController.clear,
                  child: const Text('Clear search'),
                ),
              ),
            )
          else ...[
            LibraryHub(
              selectedSection: _selectedSection,
              onSectionChanged: (section) =>
                  setState(() => _selectedSection = section),
              contents: contents,
              hasQuery: hasQuery,
              actions: LibraryActions.standard(context, ref),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
          ],
        ],
      ),
    );
  }

  LibraryContents _filter({
    required String query,
    required List<WatchProgress> continueWatching,
    required List<LocalMediaFile> recentDownloads,
    required List<LocalMediaFile> movies,
    required List<ShowWithSeasons> shows,
    required List<LocalMediaFile> allFiles,
  }) {
    if (query.isEmpty) {
      return LibraryContents(
        continueWatching: continueWatching,
        recentDownloads: recentDownloads,
        movies: movies,
        shows: shows,
        allCount: allFiles.length,
      );
    }
    bool hit(String text) => text.toLowerCase().contains(query);
    return LibraryContents(
      continueWatching: continueWatching
          .where((p) => hit(watchProgressTitle(p)) || hit(p.displayTitle))
          .toList(),
      recentDownloads: recentDownloads
          .where((f) => hit(f.displayTitle))
          .toList(),
      movies: movies.where((f) => hit(f.displayTitle)).toList(),
      shows: shows.where((s) => hit(s.showName)).toList(),
      allCount: allFiles.where((f) => hit(f.displayTitle)).length,
    );
  }

  /// Rescan the downloads folder, then tidy and reconcile watched state.
  Future<void> _rescan() async {
    refreshLocalMedia(ref);
    await ref.read(localMediaFilesProvider.future);
    if (!mounted) return;
    // Drop progress for files that no longer exist (watched-only entries
    // are kept, so the history survives deleting a file).
    await ref.read(watchProgressProvider.notifier).cleanupStaleEntries();
    if (!mounted) return;
    // Pull TMDB-rated → local and push local-watched → TMDB. Additive both
    // ways; server state is never deleted because of a local absence.
    await reconcileWatchedWithTmdb(ref);
  }

  /// Pull-to-refresh: the indicator is the feedback, failures get a toast.
  Future<void> _pullToRefresh() async {
    try {
      await _rescan();
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.showError(
        context,
        message: friendlyErrorMessage(e, subject: 'your downloads folder'),
      );
    }
  }

  /// [_rescan] with a busy button and a result — the button used to give
  /// no sign that anything happened.
  Future<void> _rescanFromButton() async {
    if (_rescanning) return;
    setState(() => _rescanning = true);
    try {
      await _rescan();
      if (!mounted) return;
      final count = ref.read(localMediaFilesProvider).value?.length ?? 0;
      AppSnackBar.showInfo(
        context,
        message: count == 1
            ? 'Library rescanned · 1 file'
            : 'Library rescanned · $count files',
      );
    } catch (e) {
      if (!mounted) return;
      AppSnackBar.showError(
        context,
        message: friendlyErrorMessage(e, subject: 'your downloads folder'),
      );
    } finally {
      if (mounted) setState(() => _rescanning = false);
    }
  }
}
