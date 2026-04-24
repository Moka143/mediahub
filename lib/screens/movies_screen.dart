import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/movie.dart';
import '../providers/movies_provider.dart';
import '../widgets/movie_card.dart';
import 'movie_details_screen.dart';

/// Screen for browsing and searching movies
class MoviesScreen extends ConsumerStatefulWidget {
  const MoviesScreen({super.key});

  @override
  ConsumerState<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends ConsumerState<MoviesScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;
  bool _isSearching = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    setState(() => _isSearching = value.isNotEmpty);

    if (value.isEmpty) {
      ref.read(movieSearchQueryProvider.notifier).clear();
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      ref.read(movieSearchQueryProvider.notifier).set(value);
      if (mounted) {
        setState(() => _isSearching = false);
      }
    });
  }

  void _onClear() {
    _searchController.clear();
    _debounceTimer?.cancel();
    setState(() => _isSearching = false);
    ref.read(movieSearchQueryProvider.notifier).clear();
  }

  void _navigateToMovieDetails(Movie movie) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => MovieDetailsScreen(movie: movie)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searchQuery = ref.watch(movieSearchQueryProvider);
    final searchResults = ref.watch(movieSearchResultsProvider);
    final trendingMovies = ref.watch(trendingMoviesProvider);
    final popularMovies = ref.watch(popularMoviesProvider);
    final topRatedMovies = ref.watch(topRatedMoviesProvider);
    final upcomingMovies = ref.watch(upcomingMoviesProvider);

    final isSearchActive = searchQuery.isNotEmpty;

    return Column(
      children: [
        // Search bar
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
            vertical: AppSpacing.sm,
          ),
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search movies...',
              prefixIcon: _isSearching
                  ? Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    )
                  : const Icon(Icons.search_rounded),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: _onClear,
                    )
                  : null,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withAlpha(
                AppOpacity.medium,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
              ),
              contentPadding: EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.md,
              ),
            ),
          ),
        ),

        // Content
        Expanded(
          child: isSearchActive
              ? _buildSearchResults(searchResults)
              : _buildBrowseContent(
                  trendingMovies,
                  popularMovies,
                  topRatedMovies,
                  upcomingMovies,
                ),
        ),
      ],
    );
  }

  Widget _buildSearchResults(AsyncValue<List<Movie>> searchResults) {
    return searchResults.when(
      data: (movies) => movies.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.search_off_rounded,
                    size: 64,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withAlpha(AppOpacity.medium),
                  ),
                  SizedBox(height: AppSpacing.md),
                  Text(
                    'No movies found',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : MovieCardGrid(
              movies: movies,
              onMovieTap: _navigateToMovieDetails,
              controller: _scrollController,
            ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            SizedBox(height: AppSpacing.md),
            Text('Error: $error'),
            SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: () => ref.invalidate(movieSearchResultsProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowseContent(
    AsyncValue<List<Movie>> trendingMovies,
    AsyncValue<List<Movie>> popularMovies,
    AsyncValue<List<Movie>> topRatedMovies,
    AsyncValue<List<Movie>> upcomingMovies,
  ) {
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(trendingMoviesProvider);
        ref.invalidate(popularMoviesProvider);
        ref.invalidate(topRatedMoviesProvider);
        ref.invalidate(upcomingMoviesProvider);
      },
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: AppSpacing.lg),

            // Trending this week
            AsyncMovieRow(
              movies: trendingMovies,
              title: 'Trending This Week',
              onMovieTap: _navigateToMovieDetails,
              onRetry: () => ref.invalidate(trendingMoviesProvider),
            ),

            SizedBox(height: AppSpacing.xl),

            // Popular
            AsyncMovieRow(
              movies: popularMovies,
              title: 'Popular',
              onMovieTap: _navigateToMovieDetails,
              onRetry: () => ref.invalidate(popularMoviesProvider),
            ),

            SizedBox(height: AppSpacing.xl),

            // Top Rated
            AsyncMovieRow(
              movies: topRatedMovies,
              title: 'Top Rated',
              onMovieTap: _navigateToMovieDetails,
              onRetry: () => ref.invalidate(topRatedMoviesProvider),
            ),

            SizedBox(height: AppSpacing.xl),

            // Upcoming
            AsyncMovieRow(
              movies: upcomingMovies,
              title: 'Coming Soon',
              onMovieTap: _navigateToMovieDetails,
              onRetry: () => ref.invalidate(upcomingMoviesProvider),
            ),

            SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}
