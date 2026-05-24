import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/show.dart';
import '../providers/shows_provider.dart';
import '../widgets/common/browse_filter_bar.dart';
import '../widgets/common/browse_pagination_footer.dart';
import '../widgets/common/browse_sort_picker.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/media/media_poster_card.dart';
import '../widgets/mediahub_spotlight.dart';
import 'show_details_screen.dart';

/// Sort/feed selector. Only meaningful when the genre filter is
/// `All` — otherwise the discover endpoint always sorts by popularity.
enum _ShowsFeed { trending, popular, topRated, onAir }

extension on _ShowsFeed {
  String get label => switch (this) {
    _ShowsFeed.trending => 'Trending',
    _ShowsFeed.popular => 'Popular',
    _ShowsFeed.topRated => 'Top Rated',
    _ShowsFeed.onAir => 'On The Air',
  };
}

/// MediaHub TV Shows browse — Stremio-style poster wall with paginated
/// lazy-loading. Picks come from:
///   * `discover/tv?with_genres=<id>` when a genre chip is active
///   * `popular/trending/top_rated/on_the_air` when `All` is selected
class ShowsScreen extends ConsumerStatefulWidget {
  const ShowsScreen({super.key});

  @override
  ConsumerState<ShowsScreen> createState() => _ShowsScreenState();
}

class _ShowsScreenState extends ConsumerState<ShowsScreen> {
  final ScrollController _scrollController = ScrollController();
  final List<Show> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _exhausted = false;
  Object? _error;

  String _genre = 'All';
  _ShowsFeed _feed = _ShowsFeed.trending;

  /// Each chip maps to one or more TMDB TV genre IDs. Empty list for
  /// `All` means no genre filter — falls back to feed providers.
  static const _genreMap = <String, List<int>>{
    'All': <int>[],
    'Drama': [18],
    'Sci-Fi': [10765], // Sci-Fi & Fantasy
    'Comedy': [35],
    'Fantasy': [10765],
    'Crime': [80],
    'Animation': [16],
  };
  List<String> get _genres => _genreMap.keys.toList();

  late final TextEditingController _searchController;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchController = TextEditingController(
      text: ref.read(showSearchQueryProvider),
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

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 280),
      () => ref.read(showSearchQueryProvider.notifier).set(value),
    );
  }

  /// Trigger pagination ~600px before the bottom — gives us a buffer
  /// so the user never sees an empty grid while we fetch the next page.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      _loadMore();
    }
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
          // TMDB list endpoints cap around 500 pages, but in practice
          // we'll hit an empty page well before then.
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

  Future<List<Show>> _fetchPage(int page) async {
    final svc = ref.read(tmdbApiServiceProvider);
    final ids = _genreMap[_genre] ?? const <int>[];
    if (ids.isEmpty) {
      return switch (_feed) {
        _ShowsFeed.trending => svc.getTrendingShows(page: page),
        _ShowsFeed.popular => svc.getPopularShows(page: page),
        _ShowsFeed.topRated => svc.getTopRatedShows(page: page),
        _ShowsFeed.onAir => svc.getOnTheAirShows(page: page),
      };
    }
    final sortBy = switch (_feed) {
      _ShowsFeed.popular => 'popularity.desc',
      _ShowsFeed.topRated => 'vote_average.desc',
      _ShowsFeed.onAir => 'first_air_date.desc',
      _ShowsFeed.trending => 'popularity.desc',
    };
    return svc.discoverShows(
      page: page,
      withGenres: ids.join(','),
      sortBy: sortBy,
      // Skip vanity entries with very few votes when sorting by rating.
      voteAverageGte: _feed == _ShowsFeed.topRated ? 7.0 : null,
    );
  }

  void _navigateToShowDetails(
    Show show, {
    bool autoOpenEpisodesDrawer = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShowDetailsScreen(
          show: show,
          autoOpenEpisodesDrawer: autoOpenEpisodesDrawer,
        ),
      ),
    );
  }

  Widget _showCard(Show show) {
    return MediaPosterCard(
      title: show.name,
      onTap: () => _navigateToShowDetails(show),
      posterAsync: AsyncValue.data(show.posterUrl),
      titleStyle: CardTitleStyle.overlay,
      overlayYear: show.year,
      overlayRating: show.voteAverage > 0
          ? '★ ${show.voteAverage.toStringAsFixed(1)}'
          : null,
      overlayRatingTone: show.voteAverage >= 8 ? AppColors.accent : null,
      width: null,
    );
  }

  double _hueFromId(int id) => (id * 37 % 360).toDouble();

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(showSearchQueryProvider);
    final isSearching = searchQuery.isNotEmpty;
    return RefreshIndicator(
      onRefresh: () async => _resetAndLoad(),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          // Keep the browse layout cohesive on ultra-wide monitors.
          // 1500 fits ~9 columns of 160-170px posters with gutters,
          // so cards never feel like they're hovering in a void.
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
                key: const ValueKey('mh-shows-spotlight'),
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
                            title: _items.first.name,
                            year: _items.first.year,
                            genre: _items.first.genres.isNotEmpty
                                ? _items.first.genres.first
                                : 'Drama',
                            rating: _items.first.voteAverage,
                            hue: _hueFromId(_items.first.id),
                            backdropUrl: _items.first.backdropUrl,
                            posterUrl: _items.first.posterUrl,
                            metaSuffix: 'TV SERIES',
                            onPrimaryTap: () => _navigateToShowDetails(
                              _items.first,
                              autoOpenEpisodesDrawer: true,
                            ),
                            onSecondaryTap: () =>
                                _navigateToShowDetails(_items.first),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ),
              // Stable key — preserves the TextField's element (and focus)
              // across rebuilds when conditional slivers above/below shift.
              SliverToBoxAdapter(
                key: const ValueKey('mh-shows-filter-bar'),
                child: BrowseFilterBar(
                  genres: _genres,
                  selectedGenre: _genre,
                  onGenreSelected: (g) {
                    setState(() => _genre = g);
                    _resetAndLoad();
                  },
                  sortPicker: BrowseSortPicker<_ShowsFeed>(
                    value: _feed,
                    options: _ShowsFeed.values,
                    labelOf: (f) => f.label,
                    onChanged: (f) {
                      setState(() => _feed = f);
                      _resetAndLoad();
                    },
                  ),
                  searchController: _searchController,
                  onSearchChanged: _onSearchChanged,
                  searchActive: isSearching,
                  searchHint: 'Search shows…',
                ),
              ),
              if (isSearching)
                ..._buildSearchSlivers(searchQuery)
              else
                ..._buildFeedSlivers(),
              // Footer also animates its height so the bottom doesn't jump
              // when search hides pagination state.
              SliverToBoxAdapter(
                key: const ValueKey('mh-shows-pagination-footer'),
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

  /// Slivers for the trending / popular / genre feed (no active search).
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
                'No shows match this filter.',
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
            maxCrossAxisExtent: 170,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 2 / 3.2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _showCard(_items[i]),
            childCount: _items.length,
          ),
        ),
      ),
    ];
  }

  /// Slivers for the search-results path. TMDB's `/search/tv` returns one
  /// page of results — enough for the typical "I'm hunting one title"
  /// case. No pagination here.
  ///
  /// We deliberately don't use `async.when` here — that would swap the grid
  /// for a spinner on every keystroke. Instead we read `.value` (which in
  /// Riverpod 3 retains the previous data while the new query is in flight)
  /// so the previous results stay visible until the new ones arrive. Avoids
  /// the "design flickers" symptom while typing.
  List<Widget> _buildSearchSlivers(String query) {
    final async = ref.watch(showSearchResultsProvider);
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
                ref.read(showSearchQueryProvider.notifier).set(query),
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
                'No shows match "$query".',
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
            (context, i) => _showCard(results[i]),
            childCount: results.length,
          ),
        ),
      ),
    ];
  }
}
