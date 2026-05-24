import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/movie.dart';
import '../providers/movies_provider.dart';
import '../providers/shows_provider.dart' show tmdbApiServiceProvider;
import '../providers/watch_progress_provider.dart';
import '../widgets/common/browse_filter_bar.dart';
import '../widgets/common/browse_pagination_footer.dart';
import '../widgets/common/browse_sort_picker.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/mediahub_spotlight.dart';
import 'movie_details_screen.dart';

enum _MoviesFeed { trending, popular, topRated, upcoming }

extension on _MoviesFeed {
  String get label => switch (this) {
    _MoviesFeed.trending => 'Trending',
    _MoviesFeed.popular => 'Popular',
    _MoviesFeed.topRated => 'Top Rated',
    _MoviesFeed.upcoming => 'New Releases',
  };
}

/// MediaHub Movies browse — paginated lazy-loading poster wall.
/// Sources:
///   * `discover/movie?with_genres=<id>` when a genre chip is active
///   * `popular/trending/top_rated/upcoming` when `All` is selected
class MoviesScreen extends ConsumerStatefulWidget {
  const MoviesScreen({super.key});

  @override
  ConsumerState<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends ConsumerState<MoviesScreen> {
  final ScrollController _scrollController = ScrollController();
  final List<Movie> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _exhausted = false;
  Object? _error;

  String _genre = 'All';
  _MoviesFeed _feed = _MoviesFeed.trending;

  /// Snapshot of TMDB movie ids the user has watched. Recomputed each
  /// build from `watchProgressProvider`, used to flag movie cards.
  Set<int> _watchedMovieIds = const {};

  /// Local controller for the search field — debounced so we don't fire a
  /// TMDB search on every keystroke. Empty query falls back to the feed.
  late final TextEditingController _searchController;
  Timer? _searchDebounce;

  static const _genreMap = <String, List<int>>{
    'All': <int>[],
    'Sci-Fi': [878],
    'Drama': [18],
    'Action': [28],
    'Horror': [27],
    'Animation': [16],
    'Thriller': [53],
  };
  List<String> get _genres => _genreMap.keys.toList();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchController = TextEditingController(
      text: ref.read(movieSearchQueryProvider),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _resetAndLoad());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Update the search query provider with a 280 ms debounce — covers
  /// typical typing cadence without flooding TMDB.
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 280),
      () => ref.read(movieSearchQueryProvider.notifier).set(value),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) _loadMore();
  }

  void _resetAndLoad() {
    setState(() {
      _items.clear();
      _page = 1;
      _loading = false;
      _exhausted = false;
      _error = null;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _exhausted) return;
    setState(() => _loading = true);
    try {
      final newPage = await _fetchPage(_page);
      if (!mounted) return;
      setState(() {
        if (newPage.isEmpty) {
          _exhausted = true;
        } else {
          _items.addAll(newPage);
          _page += 1;
          if (newPage.length < 15) _exhausted = true;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<Movie>> _fetchPage(int page) async {
    final svc = ref.read(tmdbApiServiceProvider);
    final ids = _genreMap[_genre] ?? const <int>[];
    if (ids.isEmpty) {
      return switch (_feed) {
        _MoviesFeed.trending => svc.getTrendingMovies(page: page),
        _MoviesFeed.popular => svc.getPopularMovies(page: page),
        _MoviesFeed.topRated => svc.getTopRatedMovies(page: page),
        _MoviesFeed.upcoming => svc.getUpcomingMovies(page: page),
      };
    }
    final sortBy = switch (_feed) {
      _MoviesFeed.popular => 'popularity.desc',
      _MoviesFeed.topRated => 'vote_average.desc',
      _MoviesFeed.upcoming => 'release_date.desc',
      _MoviesFeed.trending => 'popularity.desc',
    };
    return svc.discoverMovies(
      page: page,
      withGenres: ids.join(','),
      sortBy: sortBy,
      voteAverageGte: _feed == _MoviesFeed.topRated ? 7.0 : null,
    );
  }

  void _navigateToMovieDetails(
    Movie movie, {
    bool autoOpenTorrentPicker = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MovieDetailsScreen(
          movie: movie,
          autoOpenTorrentPicker: autoOpenTorrentPicker,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(movieSearchQueryProvider);
    final isSearching = searchQuery.isNotEmpty;

    // Watched-movies set — drives the "WATCHED" ribbon on each card.
    // Computed in build so a mark/unmark triggers a rebuild and the
    // ribbon appears/disappears live.
    _watchedMovieIds = ref
        .watch(watchProgressProvider)
        .values
        .where((p) => p.isCompleted && p.movieId != null)
        .map((p) => p.movieId!)
        .toSet();
    return RefreshIndicator(
      onRefresh: () async => _resetAndLoad(),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          // Keep the browse layout cohesive on ultra-wide monitors.
          constraints: const BoxConstraints(maxWidth: 1500),
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Spotlight is suppressed during search — the user is hunting
              // a specific title, not browsing the trending feed. We always
              // include the sliver and animate its height so the page
              // doesn't snap-jump 500px the moment search becomes active.
              SliverToBoxAdapter(
                key: const ValueKey('mh-movies-spotlight'),
                child: AnimatedSize(
                  duration: AppDuration.normal,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: (!isSearching && _items.isNotEmpty)
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.xxl,
                            AppSpacing.xl,
                            AppSpacing.xxl,
                            AppSpacing.md,
                          ),
                          child: MediaHubSpotlight(
                            title: _items.first.title,
                            year: _items.first.year,
                            genre: _items.first.genres.isNotEmpty
                                ? _items.first.genres.first
                                : 'Drama',
                            rating: _items.first.voteAverage,
                            hue: (_items.first.id * 53 % 360).toDouble(),
                            backdropUrl: _items.first.backdropUrl,
                            posterUrl: _items.first.posterUrl,
                            metaSuffix:
                                _items.first.runtimeFormatted?.toUpperCase() ??
                                'FEATURE',
                            onPrimaryTap: () => _navigateToMovieDetails(
                              _items.first,
                              autoOpenTorrentPicker: true,
                            ),
                            onSecondaryTap: () =>
                                _navigateToMovieDetails(_items.first),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ),
              // Stable key — preserves the TextField's element (and focus)
              // across rebuilds when conditional slivers above/below shift.
              SliverToBoxAdapter(
                key: const ValueKey('mh-movies-filter-bar'),
                child: BrowseFilterBar(
                  genres: _genres,
                  selectedGenre: _genre,
                  onGenreSelected: (g) {
                    setState(() => _genre = g);
                    _resetAndLoad();
                  },
                  sortPicker: BrowseSortPicker<_MoviesFeed>(
                    value: _feed,
                    options: _MoviesFeed.values,
                    labelOf: (f) => f.label,
                    onChanged: (f) {
                      setState(() => _feed = f);
                      _resetAndLoad();
                    },
                  ),
                  searchController: _searchController,
                  onSearchChanged: _onSearchChanged,
                  searchActive: isSearching,
                  searchHint: 'Search movies…',
                ),
              ),
              if (isSearching)
                ..._buildSearchSlivers(searchQuery)
              else
                ..._buildFeedSlivers(),
              // Footer also animates its height so the bottom doesn't jump
              // when search hides pagination state.
              SliverToBoxAdapter(
                key: const ValueKey('mh-movies-pagination-footer'),
                child: AnimatedSize(
                  duration: AppDuration.normal,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: !isSearching
                      ? BrowsePaginationFooter(
                          loading: _loading,
                          exhausted: _exhausted && _items.isNotEmpty,
                          hasItems: _items.isNotEmpty,
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Slivers rendered when the user is browsing the trending / popular /
  /// genre feed (i.e. no search query). Mirrors the pre-search behaviour.
  List<Widget> _buildFeedSlivers() {
    if (_items.isEmpty && _loading) {
      return const [
        SliverFillRemaining(hasScrollBody: false, child: LoadingIndicator()),
      ];
    }
    if (_error != null && _items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState.error(
            message: _error.toString(),
            onRetry: _resetAndLoad,
          ),
        ),
      ];
    }
    if (_items.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.huge),
              child: Text(
                'No movies match this filter.',
                style: TextStyle(color: AppColors.fg2),
              ),
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            // 170px max cap keeps cards from looking oversized on wide
            // windows. Aspect 2:3.2 reserves space for the title + meta
            // lines below the poster.
            maxCrossAxisExtent: 170,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 2 / 3.2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _movieCard(_items[i]),
            childCount: _items.length,
          ),
        ),
      ),
    ];
  }

  Widget _movieCard(Movie movie) {
    return MediaPosterCard(
      title: movie.title,
      onTap: () => _navigateToMovieDetails(movie),
      posterAsync: AsyncValue.data(movie.posterUrl),
      titleStyle: CardTitleStyle.overlay,
      overlayYear: movie.year,
      overlayRating: movie.voteAverage > 0
          ? '★ ${movie.voteAverage.toStringAsFixed(1)}'
          : null,
      overlayRatingTone: movie.voteAverage >= 8 ? AppColors.accent : null,
      isWatched: _watchedMovieIds.contains(movie.id),
      width: null,
    );
  }

  /// Slivers for the search-results path. Watches `movieSearchResultsProvider`
  /// directly — TMDB's search endpoint is not paginated here (single page is
  /// already plenty for the typical "I'm hunting one title" use case).
  ///
  /// We deliberately don't use `async.when` here — that would swap the grid
  /// for a spinner on every keystroke. Instead we read `.value` (which in
  /// Riverpod 3 retains the previous data while the new query is in flight)
  /// so the previous results stay visible until the new ones arrive. Avoids
  /// the "design flickers" symptom while typing.
  List<Widget> _buildSearchSlivers(String query) {
    final async = ref.watch(movieSearchResultsProvider);
    final results = async.value;
    final isInitialLoad = results == null && async.isLoading;
    final hasErrorWithNoData = async.hasError && results == null;

    if (hasErrorWithNoData) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState.error(
            message: async.error.toString(),
            onRetry: () =>
                ref.read(movieSearchQueryProvider.notifier).set(query),
          ),
        ),
      ];
    }

    if (isInitialLoad) {
      return const [
        SliverFillRemaining(hasScrollBody: false, child: LoadingIndicator()),
      ];
    }

    // results is non-null here. Empty means TMDB came back with no matches
    // for the *current* query — only show the "no matches" state once the
    // request has actually settled (not while a new query is still loading).
    if (results!.isEmpty && !async.isLoading) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.huge),
              child: Text(
                'No movies match "$query".',
                style: const TextStyle(color: AppColors.fg2),
              ),
            ),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 170,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 2 / 3.2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _movieCard(results[i]),
            childCount: results.length,
          ),
        ),
      ),
    ];
  }
}
