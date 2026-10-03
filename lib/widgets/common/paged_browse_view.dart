import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../providers/shows_provider.dart' show tmdbApiServiceProvider;
import '../../services/tmdb_api_service.dart';
import '../../utils/error_messages.dart';
import 'browse_filter_bar.dart';
import 'browse_pagination_footer.dart';
import 'browse_picker.dart';
import 'empty_state.dart';
import 'loading_state.dart';

/// Loads one page (1-based) of a feed.
typedef BrowsePageLoader<T> = Future<List<T>> Function(int page);

/// Page-by-page loading for a browse feed, safe against switching feeds
/// mid-request.
///
/// Movies and TV Shows each carried a copy of this and both had the same
/// race: changing filter reset the list while the old request was still in
/// flight, and when that request landed its results were appended to the
/// new filter's list — "Action" posters under "Horror" — and the page
/// counter skipped ahead. Every [reset] now starts a new *generation*, and a
/// response from an older generation is dropped on arrival.
class BrowsePager<T> extends ChangeNotifier {
  BrowsePager({this.keyOf, this.fullPageSize = 15});

  /// Identity of an item, used to drop duplicates: TMDB feeds shift between
  /// page requests, so page 2 can repeat the tail of page 1.
  final Object Function(T item)? keyOf;

  /// A page shorter than this is taken to be the last.
  final int fullPageSize;

  final List<T> _items = [];
  final Set<Object> _keys = {};
  BrowsePageLoader<T>? _loader;
  int _nextPage = 1;
  int _generation = 0;
  bool _loading = false;
  bool _exhausted = false;
  Object? _error;
  bool _disposed = false;

  List<T> get items => UnmodifiableListView(_items);
  bool get loading => _loading;
  bool get exhausted => _exhausted;

  /// Why the most recent page failed, until the next attempt.
  Object? get error => _error;

  /// The page the next [loadMore] will request.
  @visibleForTesting
  int get nextPage => _nextPage;

  /// Start over with [loader], dropping whatever is still in flight.
  Future<void> reset(BrowsePageLoader<T> loader) {
    _generation++;
    _loader = loader;
    _items.clear();
    _keys.clear();
    _nextPage = 1;
    _loading = false;
    _exhausted = false;
    _error = null;
    _notify();
    return loadMore(retry: true);
  }

  /// Fetch the next page.
  ///
  /// A failed page stays failed until asked again with [retry] — otherwise
  /// every scroll event near the bottom would hammer a server that is down.
  Future<void> loadMore({bool retry = false}) async {
    final loader = _loader;
    if (loader == null || _loading || _exhausted) return;
    if (_error != null && !retry) return;

    final generation = _generation;
    _loading = true;
    _error = null;
    _notify();
    try {
      final page = await loader(_nextPage);
      if (generation != _generation || _disposed) return;
      var added = 0;
      for (final item in page) {
        final key = keyOf?.call(item);
        if (key != null && !_keys.add(key)) continue;
        _items.add(item);
        added++;
      }
      _nextPage++;
      // A short page is the last one. So is a page with nothing new in it:
      // asking again would only fetch more of what is already here.
      if (page.length < fullPageSize || added == 0) _exhausted = true;
    } catch (e) {
      if (generation != _generation || _disposed) return;
      _error = e;
    } finally {
      // A stale generation must not touch the flag: it belongs to the
      // request the newer generation has in flight.
      if (generation == _generation && !_disposed) {
        _loading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A choice in a browse screen's genre picker.
@immutable
class BrowseGenre {
  const BrowseGenre(this.label, [this.ids = const []]);

  /// "All genres", then every genre in [tmdbGenres] (TMDB id → name) from A
  /// to Z. The picker used to offer six hand-picked chips; TMDB has 19 movie
  /// genres and 16 TV ones, and discover filters on any of them.
  static List<BrowseGenre> listFrom(Map<int, String> tmdbGenres) {
    final byName = tmdbGenres.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return [
      const BrowseGenre(allLabel),
      for (final genre in byName) BrowseGenre(genre.value, [genre.key]),
    ];
  }

  /// The unfiltered choice's label — on the picker's button, so it names
  /// what "all" is of.
  static const String allLabel = 'All genres';

  final String label;

  /// TMDB genre ids; empty for "All".
  final List<int> ids;

  bool get isAll => ids.isEmpty;
}

/// A feed choice in a browse screen's sort picker.
@immutable
class BrowseFeed {
  const BrowseFeed(this.label);

  final String label;
}

/// A `discover` query: the sort, an optional release year, and a vote floor.
typedef DiscoverQuery = ({String sortBy, int? year, int? minVotes});

/// The `discover` query for a genre-filtered [feed], for either media type.
///
/// Discover has no "trending" sort, and Trending used to send the same
/// `popularity.desc` as Popular — two menu entries, one result. Trending is
/// what is popular among this year's releases. Top rated sorts by the
/// average, but only among titles with at least [topRatedMinVotes] votes:
/// the bare average puts titles with three 10/10 votes first. [latest]
/// sorts by [latestSortBy].
DiscoverQuery discoverQueryFor(
  BrowseFeed feed, {
  required BrowseFeed trending,
  required BrowseFeed topRated,
  required BrowseFeed latest,
  required String latestSortBy,
  required int topRatedMinVotes,
  DateTime? now,
}) {
  if (identical(feed, trending)) {
    return (
      sortBy: 'popularity.desc',
      year: (now ?? DateTime.now()).year,
      minVotes: null,
    );
  }
  if (identical(feed, topRated)) {
    return (
      sortBy: 'vote_average.desc',
      year: null,
      minVotes: topRatedMinVotes,
    );
  }
  if (identical(feed, latest)) {
    return (sortBy: latestSortBy, year: null, minVotes: null);
  }
  return (sortBy: 'popularity.desc', year: null, minVotes: null);
}

/// What differs between the Movies and the TV Shows browse screens. Paging,
/// search, the filter row, the loading / error / empty states and the grid
/// are [PagedBrowseView]'s.
abstract class BrowseConfig<T> {
  const BrowseConfig();

  /// Prefix for the sliver keys that keep the search field's focus.
  String get keyPrefix;

  /// Plural noun for copy — "movies", "shows".
  String get noun;

  String get searchHint;
  List<BrowseGenre> get genres;
  List<BrowseFeed> get feeds;

  /// Page [page] of [feed], narrowed to [genre].
  Future<List<T>> fetchPage(
    TmdbApiService tmdb, {
    required BrowseFeed feed,
    required BrowseGenre genre,
    required int page,
  });

  String watchSearchQuery(WidgetRef ref);
  String readSearchQuery(WidgetRef ref);
  void setSearchQuery(WidgetRef ref, String query);
  AsyncValue<List<T>> watchSearchResults(WidgetRef ref);

  /// Identity for de-duplication across pages.
  int idOf(T item);

  Widget buildCard(BuildContext context, T item);

  /// The hero above the grid, for the first item of the feed.
  Widget buildSpotlight(
    BuildContext context,
    T item, {
    required BrowseFeed feed,
    required BrowseGenre genre,
  });
}

/// The shared browse screen: spotlight, filter row, paged poster grid, and
/// search.
class PagedBrowseView<T> extends ConsumerStatefulWidget {
  const PagedBrowseView({super.key, required this.config, this.onOpenSettings});

  final BrowseConfig<T> config;

  /// Where to send someone whose TMDB token was rejected.
  final void Function(BuildContext context)? onOpenSettings;

  @override
  ConsumerState<PagedBrowseView<T>> createState() => _PagedBrowseViewState<T>();
}

class _PagedBrowseViewState<T> extends ConsumerState<PagedBrowseView<T>> {
  final ScrollController _scrollController = ScrollController();
  late final BrowsePager<T> _pager = BrowsePager<T>(
    keyOf: (item) => widget.config.idOf(item),
  );
  late final TextEditingController _searchController;
  Timer? _searchDebounce;

  late BrowseGenre _genre = widget.config.genres.first;
  late BrowseFeed _feed = widget.config.feeds.first;

  BrowseConfig<T> get _config => widget.config;

  static const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    // 170px keeps cards from looking oversized on wide windows; the overlay
    // card is a bare 2:3 poster, so the aspect needs no text allowance.
    maxCrossAxisExtent: 170,
    mainAxisSpacing: AppSpacing.md,
    crossAxisSpacing: AppSpacing.md,
    childAspectRatio: 2 / 3,
  );

  /// How long typing must pause before a search runs: typical typing
  /// cadence, without a TMDB request per keystroke.
  static const _searchDelay = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: _config.readSearchQuery(ref),
    );
    _scrollController.addListener(_onScroll);
    // Started here, before the listener is attached, so the very first frame
    // already shows the loading skeleton. It used to start a frame later and
    // the TV Shows grid sat blank — no spinner, no skeleton — until then.
    unawaited(_pager.reset(_loader()));
    _pager.addListener(_onPagerChanged);
  }

  @override
  void dispose() {
    _pager
      ..removeListener(_onPagerChanged)
      ..dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onPagerChanged() {
    if (!mounted) return;
    setState(() {});
    // A page that does not fill a tall window leaves nothing to scroll, and
    // so nothing to ask for the next one. Check again once it is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  BrowsePageLoader<T> _loader() {
    final tmdb = ref.read(tmdbApiServiceProvider);
    final feed = _feed;
    final genre = _genre;
    return (page) =>
        _config.fetchPage(tmdb, feed: feed, genre: genre, page: page);
  }

  Future<void> _reload() => _pager.reset(_loader());

  /// Pagination starts ~600px before the bottom so the grid never runs dry
  /// in view.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) unawaited(_pager.loadMore());
  }

  /// Debounced by [_searchDelay].
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      _searchDelay,
      () => _config.setSearchQuery(ref, value),
    );
  }

  Widget _errorState(Object error, VoidCallback onRetry) {
    final needsSettings =
        failureNeedsSettings(error) && widget.onOpenSettings != null;
    return EmptyState.error(
      title: "Couldn't load ${_config.noun}",
      message: friendlyErrorMessage(error, subject: _config.noun),
      onRetry: onRetry,
      secondaryLabel: needsSettings ? 'Open Settings' : null,
      onSecondary: needsSettings ? () => widget.onOpenSettings!(context) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = _config.watchSearchQuery(ref);
    final isSearching = searchQuery.isNotEmpty;
    final items = _pager.items;
    final prefix = _config.keyPrefix;

    return RefreshIndicator(
      onRefresh: _reload,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          // Keeps the layout cohesive on ultra-wide monitors.
          constraints: const BoxConstraints(maxWidth: 1500),
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // Suppressed during search — the user is hunting one title,
              // not browsing. Always present and animated so the page does
              // not snap-jump the moment search becomes active.
              SliverToBoxAdapter(
                key: ValueKey('mh-$prefix-spotlight'),
                child: AnimatedSize(
                  duration: AppDuration.normal,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: (!isSearching && items.isNotEmpty)
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.xxl,
                            AppSpacing.xl,
                            AppSpacing.xxl,
                            AppSpacing.md,
                          ),
                          child: _config.buildSpotlight(
                            context,
                            items.first,
                            feed: _feed,
                            genre: _genre,
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ),
              // Stable key — keeps the search field's element (and focus)
              // when the conditional slivers around it change.
              SliverToBoxAdapter(
                key: ValueKey('mh-$prefix-filter-bar'),
                child: BrowseFilterBar(
                  genrePicker: BrowsePicker<BrowseGenre>(
                    value: _genre,
                    options: _config.genres,
                    labelOf: (g) => g.label,
                    icon: Icons.category_outlined,
                    tooltip: 'Genre',
                    enabled: !isSearching,
                    onChanged: (genre) {
                      if (identical(genre, _genre)) return;
                      setState(() => _genre = genre);
                      unawaited(_reload());
                    },
                  ),
                  sortPicker: BrowsePicker<BrowseFeed>(
                    value: _feed,
                    options: _config.feeds,
                    labelOf: (f) => f.label,
                    icon: Icons.sort_rounded,
                    tooltip: 'Sort',
                    enabled: !isSearching,
                    onChanged: (feed) {
                      if (identical(feed, _feed)) return;
                      setState(() => _feed = feed);
                      unawaited(_reload());
                    },
                  ),
                  searchController: _searchController,
                  onSearchChanged: _onSearchChanged,
                  searchActive: isSearching,
                  searchHint: _config.searchHint,
                ),
              ),
              if (isSearching)
                ..._searchSlivers(searchQuery)
              else
                ..._feedSlivers(items),
              SliverToBoxAdapter(
                key: ValueKey('mh-$prefix-pagination-footer'),
                child: AnimatedSize(
                  duration: AppDuration.normal,
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: !isSearching
                      ? BrowsePaginationFooter(
                          loading: _pager.loading && items.isNotEmpty,
                          exhausted: _pager.exhausted && items.isNotEmpty,
                          hasItems: items.isNotEmpty,
                          error: items.isNotEmpty ? _pager.error : null,
                          onRetry: () =>
                              unawaited(_pager.loadMore(retry: true)),
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

  List<Widget> _feedSlivers(List<T> items) {
    if (items.isEmpty) {
      final error = _pager.error;
      if (error != null && !_pager.loading) {
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _errorState(error, () => unawaited(_reload())),
          ),
        ];
      }
      if (_pager.loading) return _skeletonSlivers();
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.filter_alt_off_rounded,
            title: 'No ${_config.noun} match this filter',
            subtitle: 'Try another genre or feed.',
          ),
        ),
      ];
    }
    return [_grid(items)];
  }

  Widget _grid(List<T> items) => SliverPadding(
    padding: const EdgeInsets.all(AppSpacing.xxl),
    sliver: SliverGrid(
      gridDelegate: _gridDelegate,
      delegate: SliverChildBuilderDelegate(
        (context, i) => _config.buildCard(context, items[i]),
        childCount: items.length,
      ),
    ),
  );

  /// A progress bar over poster-shaped placeholders while the first page
  /// loads — the shape of what is coming, and proof that it is.
  List<Widget> _skeletonSlivers() => [
    const SliverPadding(
      padding: EdgeInsets.only(
        left: AppSpacing.xxl,
        top: AppSpacing.xxl,
        right: AppSpacing.xxl,
      ),
      sliver: SliverToBoxAdapter(
        child: LinearProgressIndicator(
          minHeight: 2,
          color: AppColors.accent,
          backgroundColor: AppColors.line,
        ),
      ),
    ),
    SliverPadding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      sliver: SliverGrid(
        gridDelegate: _gridDelegate,
        delegate: SliverChildBuilderDelegate(
          (context, i) => const _PosterSkeleton(),
          childCount: 12,
        ),
      ),
    ),
  ];

  /// Slivers for search results. TMDB's search returns one page — plenty
  /// for hunting a single title.
  ///
  /// Reads `.value` rather than `when` so the previous results stay up while
  /// the next query loads; swapping the grid for a spinner on every keystroke
  /// made the page flicker.
  List<Widget> _searchSlivers(String query) {
    final async = _config.watchSearchResults(ref);
    final results = async.value;

    if (async.hasError && results == null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _errorState(
            async.error!,
            () => _config.setSearchQuery(ref, query),
          ),
        ),
      ];
    }
    if (results == null) {
      return const [
        SliverFillRemaining(hasScrollBody: false, child: LoadingIndicator()),
      ];
    }
    if (results.isEmpty && !async.isLoading) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState.noResults(
            title: 'No ${_config.noun} match "$query"',
            subtitle: 'Check the spelling, or try fewer words.',
          ),
        ),
      ];
    }
    return [_grid(results)];
  }
}

class _PosterSkeleton extends StatelessWidget {
  const _PosterSkeleton();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
    );
  }
}
