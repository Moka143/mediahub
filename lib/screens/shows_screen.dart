import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/show.dart';
import '../providers/shows_provider.dart';
import '../widgets/common/browse_search_pill.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/mediahub_chip.dart';
import '../widgets/mediahub_spotlight.dart';
import '../widgets/show_card.dart';
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

  void _navigateToShowDetails(Show show) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ShowDetailsScreen(show: show)));
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
                      title: _items.first.name,
                      year: _items.first.year,
                      genre: _items.first.genres.isNotEmpty
                          ? _items.first.genres.first
                          : 'Drama',
                      rating: _items.first.voteAverage,
                      quality: '4K',
                      hue: _hueFromId(_items.first.id),
                      backdropUrl: _items.first.backdropUrl,
                      posterUrl: _items.first.posterUrl,
                      metaSuffix: 'TV SERIES',
                      onPrimaryTap: () => _navigateToShowDetails(_items.first),
                      onSecondaryTap: () =>
                          _navigateToShowDetails(_items.first),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: _ShowsFilterBar(
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
                  child: _PaginationFooter(
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

  /// Slivers for the trending / popular / genre feed (no active search).
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
                'No shows match this filter.',
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
            maxCrossAxisExtent: 170,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
            childAspectRatio: 2 / 3.2,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => ShowCard(
              show: _items[i],
              onTap: () => _navigateToShowDetails(_items[i]),
            ),
            childCount: _items.length,
          ),
        ),
      ),
    ];
  }

  /// Slivers for the search-results path. TMDB's `/search/tv` returns one
  /// page of results — enough for the typical "I'm hunting one title"
  /// case. No pagination here.
  List<Widget> _buildSearchSlivers(String query) {
    final async = ref.watch(showSearchResultsProvider);
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
                ref.read(showSearchQueryProvider.notifier).set(query),
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
                    'No shows match "$query".',
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
                (context, i) => ShowCard(
                  show: results[i],
                  onTap: () => _navigateToShowDetails(results[i]),
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

class _PaginationFooter extends StatelessWidget {
  const _PaginationFooter({
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

class _ShowsFilterBar extends StatelessWidget {
  const _ShowsFilterBar({
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
  final _ShowsFeed feed;
  final ValueChanged<_ShowsFeed> onFeedSelected;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
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
            child: _FeedSortPicker(value: feed, onChanged: onFeedSelected),
          ),
          const SizedBox(width: AppSpacing.md),
          BrowseSearchPill(
            controller: searchController,
            onChanged: onSearchChanged,
            hint: 'Search shows…',
          ),
        ],
      ),
    );
  }
}

class _FeedSortPicker extends StatelessWidget {
  const _FeedSortPicker({required this.value, required this.onChanged});

  final _ShowsFeed value;
  final ValueChanged<_ShowsFeed> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_ShowsFeed>(
      initialValue: value,
      tooltip: 'Sort feed',
      onSelected: onChanged,
      color: AppColors.bgSurfaceHi,
      itemBuilder: (_) => _ShowsFeed.values
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
