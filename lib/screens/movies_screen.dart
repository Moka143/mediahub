import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/movie.dart';
import '../providers/movies_provider.dart';
import '../providers/shows_provider.dart' show tmdbApiServiceProvider;
import '../widgets/common/browse_search_pill.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/mediahub_chip.dart';
import '../widgets/mediahub_spotlight.dart';
import '../widgets/movie_card.dart';
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

  void _navigateToMovieDetails(Movie movie) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => MovieDetailsScreen(movie: movie)));
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(movieSearchQueryProvider);
    final isSearching = searchQuery.isNotEmpty;
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
              // a specific title, not browsing the trending feed.
              if (!isSearching && _items.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xxl,
                    AppSpacing.xl,
                    AppSpacing.xxl,
                    AppSpacing.md,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: MediaHubSpotlight(
                      title: _items.first.title,
                      year: _items.first.year,
                      genre: _items.first.genres.isNotEmpty
                          ? _items.first.genres.first
                          : 'Drama',
                      rating: _items.first.voteAverage,
                      quality: '4K',
                      hue: (_items.first.id * 53 % 360).toDouble(),
                      backdropUrl: _items.first.backdropUrl,
                      posterUrl: _items.first.posterUrl,
                      metaSuffix:
                          _items.first.runtimeFormatted?.toUpperCase() ??
                          'FEATURE',
                      onPrimaryTap: () => _navigateToMovieDetails(_items.first),
                      onSecondaryTap: () =>
                          _navigateToMovieDetails(_items.first),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: _MoviesFilterBar(
                  genres: _genres,
                  selectedGenre: _genre,
                  onGenreSelected: (g) {
                    setState(() => _genre = g);
                    _resetAndLoad();
                  },
                  feed: _feed,
                  onFeedSelected: (f) {
                    setState(() => _feed = f);
                    _resetAndLoad();
                  },
                  searchController: _searchController,
                  onSearchChanged: _onSearchChanged,
                  searchActive: isSearching,
                ),
              ),
              if (isSearching)
                ..._buildSearchSlivers(searchQuery)
              else
                ..._buildFeedSlivers(),
              if (!isSearching)
                SliverToBoxAdapter(
                  child: _MoviesPaginationFooter(
                    loading: _loading,
                    exhausted: _exhausted && _items.isNotEmpty,
                    hasItems: _items.isNotEmpty,
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
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
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
                style: TextStyle(color: Color(0xFF7A7A92)),
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
            (context, i) => MovieCard(
              movie: _items[i],
              onTap: () => _navigateToMovieDetails(_items[i]),
            ),
            childCount: _items.length,
          ),
        ),
      ),
    ];
  }

  /// Slivers for the search-results path. Watches `movieSearchResultsProvider`
  /// directly — TMDB's search endpoint is not paginated here (single page is
  /// already plenty for the typical "I'm hunting one title" use case).
  List<Widget> _buildSearchSlivers(String query) {
    final async = ref.watch(movieSearchResultsProvider);
    return async.when(
      loading: () => const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (e, _) => [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState.error(
            message: e.toString(),
            onRetry: () =>
                ref.read(movieSearchQueryProvider.notifier).set(query),
          ),
        ),
      ],
      data: (results) {
        if (results.isEmpty) {
          return [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.huge),
                  child: Text(
                    'No movies match "$query".',
                    style: const TextStyle(color: Color(0xFF7A7A92)),
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
                (context, i) => MovieCard(
                  movie: results[i],
                  onTap: () => _navigateToMovieDetails(results[i]),
                ),
                childCount: results.length,
              ),
            ),
          ),
        ];
      },
    );
  }
}

class _MoviesPaginationFooter extends StatelessWidget {
  const _MoviesPaginationFooter({
    required this.loading,
    required this.exhausted,
    required this.hasItems,
  });

  final bool loading;
  final bool exhausted;
  final bool hasItems;

  @override
  Widget build(BuildContext context) {
    if (!hasItems) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(
        bottom: AppSpacing.huge,
        top: AppSpacing.md,
      ),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : exhausted
            ? const Text(
                'You\'ve reached the end.',
                style: TextStyle(color: Color(0xFF54546A), fontSize: 12),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _MoviesFilterBar extends StatelessWidget {
  const _MoviesFilterBar({
    required this.genres,
    required this.selectedGenre,
    required this.onGenreSelected,
    required this.feed,
    required this.onFeedSelected,
    required this.searchController,
    required this.onSearchChanged,
    required this.searchActive,
  });

  final List<String> genres;
  final String selectedGenre;
  final ValueChanged<String> onGenreSelected;
  final _MoviesFeed feed;
  final ValueChanged<_MoviesFeed> onFeedSelected;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;

  /// When true the genre chips + feed sort are visually de-emphasised —
  /// they don't apply during a search and we don't want them to look
  /// interactive.
  final bool searchActive;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xxl,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: AnimatedOpacity(
              duration: AppDuration.fast,
              opacity: searchActive ? 0.4 : 1.0,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final g in genres) ...[
                      MediaHubFilterChip(
                        label: g,
                        selected: g == selectedGenre,
                        onTap: searchActive ? () {} : () => onGenreSelected(g),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          AnimatedOpacity(
            duration: AppDuration.fast,
            opacity: searchActive ? 0.4 : 1.0,
            child: _MoviesFeedSortPicker(
              value: feed,
              onChanged: onFeedSelected,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          BrowseSearchPill(
            controller: searchController,
            onChanged: onSearchChanged,
            hint: 'Search movies…',
          ),
        ],
      ),
    );
  }
}

class _MoviesFeedSortPicker extends StatelessWidget {
  const _MoviesFeedSortPicker({required this.value, required this.onChanged});

  final _MoviesFeed value;
  final ValueChanged<_MoviesFeed> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_MoviesFeed>(
      initialValue: value,
      tooltip: 'Sort feed',
      onSelected: onChanged,
      color: AppColors.bgSurfaceHi,
      itemBuilder: (_) => _MoviesFeed.values
          .map(
            (f) => PopupMenuItem(
              value: f,
              child: Text(
                f.label,
                style: const TextStyle(fontSize: 12, color: Color(0xFFF4F4F8)),
              ),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          border: Border.all(color: const Color(0x0FFFFFFF)),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort_rounded, size: 12, color: Color(0xFF7A7A92)),
            const SizedBox(width: 6),
            Text(
              value.label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFF4F4F8),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: Color(0xFF7A7A92),
            ),
          ],
        ),
      ),
    );
  }
}
