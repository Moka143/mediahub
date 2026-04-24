import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/show.dart';
import '../models/season.dart';
import '../models/episode.dart';
import '../services/tmdb_api_service.dart';
import 'settings_provider.dart';

/// Provider for TMDB API service — key is sourced from user settings.
/// Rebuilt whenever the user updates their key in onboarding/settings.
final tmdbApiServiceProvider = Provider<TmdbApiService>((ref) {
  final apiKey = ref.watch(settingsProvider.select((s) => s.tmdbApiKey));
  return TmdbApiService(apiKey: apiKey);
});

/// Search query notifier
class ShowSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void clear() => state = '';
}

/// Search query state
final showSearchQueryProvider =
    NotifierProvider<ShowSearchQueryNotifier, String>(
      ShowSearchQueryNotifier.new,
    );

/// Search results provider
final showSearchResultsProvider = FutureProvider.autoDispose<List<Show>>((
  ref,
) async {
  final query = ref.watch(showSearchQueryProvider);
  if (query.isEmpty) return [];

  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.searchShows(query);
});

/// Popular shows provider
final popularShowsProvider = FutureProvider<List<Show>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getPopularShows();
});

/// Trending shows provider (weekly)
final trendingShowsProvider = FutureProvider<List<Show>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getTrendingShows(timeWindow: 'week');
});

/// Top rated shows provider
final topRatedShowsProvider = FutureProvider<List<Show>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getTopRatedShows();
});

/// On the air shows provider
final onTheAirShowsProvider = FutureProvider<List<Show>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getOnTheAirShows();
});

/// Selected show ID notifier
class SelectedShowIdNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? value) => state = value;
  void clear() => state = null;
}

/// Selected show ID state
final selectedShowIdProvider = NotifierProvider<SelectedShowIdNotifier, int?>(
  SelectedShowIdNotifier.new,
);

/// Selected show details provider
final selectedShowProvider = FutureProvider.autoDispose<Show?>((ref) async {
  final showId = ref.watch(selectedShowIdProvider);
  if (showId == null) return null;

  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getShowDetailsWithImdb(showId);
});

/// Show details by ID (family provider for caching multiple shows)
final showDetailsProvider = FutureProvider.family<Show, int>((
  ref,
  showId,
) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getShowDetailsWithImdb(showId);
});

/// Seasons for a show
final showSeasonsProvider = FutureProvider.family<List<Season>, int>((
  ref,
  showId,
) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getShowSeasons(showId);
});

/// Selected season number notifier
class SelectedSeasonNumberNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? value) => state = value;
  void clear() => state = null;
}

/// Selected season number state
final selectedSeasonNumberProvider =
    NotifierProvider<SelectedSeasonNumberNotifier, int?>(
      SelectedSeasonNumberNotifier.new,
    );

/// Episodes for a specific season
final seasonEpisodesProvider =
    FutureProvider.family<List<Episode>, ({int showId, int seasonNumber})>((
      ref,
      params,
    ) async {
      final tmdbService = ref.read(tmdbApiServiceProvider);
      return tmdbService.getSeasonEpisodes(params.showId, params.seasonNumber);
    });

/// Similar shows provider
final similarShowsProvider = FutureProvider.family<List<Show>, int>((
  ref,
  showId,
) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getSimilarShows(showId);
});

/// Recommended shows provider
final recommendedShowsProvider = FutureProvider.family<List<Show>, int>((
  ref,
  showId,
) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getRecommendedShows(showId);
});

/// TV genres provider
final tvGenresProvider = FutureProvider<Map<int, String>>((ref) async {
  final tmdbService = ref.read(tmdbApiServiceProvider);
  return tmdbService.getGenres();
});

/// State class for shows browsing
class ShowsState {
  final List<Show> popularShows;
  final List<Show> trendingShows;
  final List<Show> searchResults;
  final String searchQuery;
  final bool isLoading;
  final bool isSearching;
  final String? error;

  const ShowsState({
    this.popularShows = const [],
    this.trendingShows = const [],
    this.searchResults = const [],
    this.searchQuery = '',
    this.isLoading = false,
    this.isSearching = false,
    this.error,
  });

  ShowsState copyWith({
    List<Show>? popularShows,
    List<Show>? trendingShows,
    List<Show>? searchResults,
    String? searchQuery,
    bool? isLoading,
    bool? isSearching,
    String? error,
  }) {
    return ShowsState(
      popularShows: popularShows ?? this.popularShows,
      trendingShows: trendingShows ?? this.trendingShows,
      searchResults: searchResults ?? this.searchResults,
      searchQuery: searchQuery ?? this.searchQuery,
      isLoading: isLoading ?? this.isLoading,
      isSearching: isSearching ?? this.isSearching,
      error: error,
    );
  }
}

/// Notifier for shows state (using the new Riverpod 2.0+ Notifier pattern)
class ShowsNotifier extends Notifier<ShowsState> {
  @override
  ShowsState build() {
    return const ShowsState();
  }

  TmdbApiService get _tmdbService => ref.read(tmdbApiServiceProvider);

  Future<void> loadPopularShows({bool refresh = false}) async {
    if (state.popularShows.isNotEmpty && !refresh) return;

    state = state.copyWith(isLoading: true, error: null);
    try {
      final shows = await _tmdbService.getPopularShows();
      state = state.copyWith(popularShows: shows, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  Future<void> loadTrendingShows({bool refresh = false}) async {
    if (state.trendingShows.isNotEmpty && !refresh) return;

    state = state.copyWith(isLoading: true, error: null);
    try {
      final shows = await _tmdbService.getTrendingShows();
      state = state.copyWith(trendingShows: shows, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  Future<void> search(String query) async {
    if (query.isEmpty) {
      state = state.copyWith(searchResults: [], searchQuery: '');
      return;
    }

    state = state.copyWith(isSearching: true, searchQuery: query, error: null);
    try {
      final shows = await _tmdbService.searchShows(query);
      state = state.copyWith(searchResults: shows, isSearching: false);
    } catch (e) {
      state = state.copyWith(error: e.toString(), isSearching: false);
    }
  }

  void clearSearch() {
    state = state.copyWith(searchResults: [], searchQuery: '');
  }
}

/// Provider for ShowsNotifier
final showsNotifierProvider = NotifierProvider<ShowsNotifier, ShowsState>(
  ShowsNotifier.new,
);
