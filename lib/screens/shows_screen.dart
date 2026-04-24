import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../providers/shows_provider.dart';
import '../models/show.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/show_card.dart';
import '../widgets/show_search_bar.dart';
import 'show_details_screen.dart';

/// Screen for browsing and searching TV shows
class ShowsScreen extends ConsumerStatefulWidget {
  const ShowsScreen({super.key});

  @override
  ConsumerState<ShowsScreen> createState() => _ShowsScreenState();
}

class _ShowsScreenState extends ConsumerState<ShowsScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _navigateToShowDetails(Show show) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => ShowDetailsScreen(show: show)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(showSearchQueryProvider);
    final searchResults = ref.watch(showSearchResultsProvider);
    final popularShows = ref.watch(popularShowsProvider);
    final trendingShows = ref.watch(trendingShowsProvider);

    final isSearching = searchQuery.isNotEmpty;

    return Column(
      children: [
        // Search bar
        ShowSearchBar(
          onSearch: (query) {
            ref.read(showSearchQueryProvider.notifier).set(query);
          },
          onClear: () {
            ref.read(showSearchQueryProvider.notifier).clear();
          },
        ),

        // Content
        Expanded(
          child: isSearching
              ? _buildSearchResults(searchResults)
              : _buildBrowseContent(popularShows, trendingShows),
        ),
      ],
    );
  }

  Widget _buildSearchResults(AsyncValue<List<Show>> searchResults) {
    return searchResults.when(
      data: (shows) => shows.isEmpty
          ? _buildEmptyState('No shows found', Icons.search_off)
          : ShowCardGrid(
              shows: shows,
              onShowTap: _navigateToShowDetails,
              controller: _scrollController,
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _buildErrorState(error.toString()),
    );
  }

  Widget _buildBrowseContent(
    AsyncValue<List<Show>> popularShows,
    AsyncValue<List<Show>> trendingShows,
  ) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(popularShowsProvider);
        ref.invalidate(trendingShowsProvider);
      },
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: AppSpacing.lg),

            // Trending this week
            trendingShows.when(
              data: (shows) => ShowCardRow(
                title: '🔥 Trending This Week',
                shows: shows,
                onShowTap: _navigateToShowDetails,
              ),
              loading: () => const ShowCardRow(
                title: '🔥 Trending This Week',
                shows: [],
                onShowTap: _dummyCallback,
                isLoading: true,
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),
            SizedBox(height: AppSpacing.xl),

            // Popular shows
            popularShows.when(
              data: (shows) => ShowCardRow(
                title: '⭐ Popular Shows',
                shows: shows,
                onShowTap: _navigateToShowDetails,
              ),
              loading: () => const ShowCardRow(
                title: '⭐ Popular Shows',
                shows: [],
                onShowTap: _dummyCallback,
                isLoading: true,
              ),
              error: (_, __) => const SizedBox.shrink(),
            ),
            SizedBox(height: AppSpacing.xl),

            // Top rated section
            _buildTopRatedSection(),
            SizedBox(height: AppSpacing.xl),

            // On the air section
            _buildOnTheAirSection(),
            SizedBox(height: AppSpacing.sectionSpacing),
          ],
        ),
      ),
    );
  }

  Widget _buildTopRatedSection() {
    final topRatedShows = ref.watch(topRatedShowsProvider);

    return topRatedShows.when(
      data: (shows) => ShowCardRow(
        title: '🏆 Top Rated',
        shows: shows,
        onShowTap: _navigateToShowDetails,
      ),
      loading: () => const ShowCardRow(
        title: '🏆 Top Rated',
        shows: [],
        onShowTap: _dummyCallback,
        isLoading: true,
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildOnTheAirSection() {
    final onTheAirShows = ref.watch(onTheAirShowsProvider);

    return onTheAirShows.when(
      data: (shows) => ShowCardRow(
        title: '📺 On The Air',
        shows: shows,
        onShowTap: _navigateToShowDetails,
      ),
      loading: () => const ShowCardRow(
        title: '📺 On The Air',
        shows: [],
        onShowTap: _dummyCallback,
        isLoading: true,
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildEmptyState(String message, IconData icon) {
    return EmptyState.noResults(
      title: message,
      subtitle: 'Try a different search term',
    );
  }

  Widget _buildErrorState(String error) {
    return EmptyState.error(
      message: error,
      onRetry: () {
        ref.invalidate(popularShowsProvider);
        ref.invalidate(trendingShowsProvider);
      },
    );
  }

  static void _dummyCallback(Show _) {}
}
