import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/eztv_torrent.dart';
import '../services/eztv_api_service.dart';

/// Provider for EZTV API service
final eztvApiServiceProvider = Provider<EztvApiService>((ref) {
  return EztvApiService();
});

/// Get torrents for a show by IMDB ID
final showTorrentsProvider = FutureProvider.family<List<EztvTorrent>, String>((
  ref,
  imdbId,
) async {
  final eztvService = ref.read(eztvApiServiceProvider);
  return eztvService.getTorrentsByImdbId(imdbId);
});

/// Get torrents for a specific episode
final episodeTorrentsProvider =
    FutureProvider.family<
      List<EztvTorrent>,
      ({String imdbId, int season, int episode})
    >((ref, params) async {
      final eztvService = ref.read(eztvApiServiceProvider);
      return eztvService.getTorrentsForEpisode(
        params.imdbId,
        season: params.season,
        episode: params.episode,
      );
    });

/// Get best torrent for an episode
final bestEpisodeTorrentProvider =
    FutureProvider.family<
      EztvTorrent?,
      ({String imdbId, int season, int episode, String? preferredQuality})
    >((ref, params) async {
      final eztvService = ref.read(eztvApiServiceProvider);
      return eztvService.getBestTorrentForEpisode(
        params.imdbId,
        season: params.season,
        episode: params.episode,
        preferredQuality: params.preferredQuality,
      );
    });

/// Check if torrents are available for an episode
final hasTorrentsProvider =
    FutureProvider.family<bool, ({String imdbId, int season, int episode})>((
      ref,
      params,
    ) async {
      final torrents = await ref.watch(episodeTorrentsProvider(params).future);
      return torrents.isNotEmpty;
    });

/// State for torrent search/filter
class TorrentSearchState {
  final String? imdbId;
  final int? season;
  final int? episode;
  final List<EztvTorrent> torrents;
  final List<EztvTorrent> filteredTorrents;
  final String? qualityFilter;
  final TorrentSortOption sortOption;
  final bool isLoading;
  final String? error;

  const TorrentSearchState({
    this.imdbId,
    this.season,
    this.episode,
    this.torrents = const [],
    this.filteredTorrents = const [],
    this.qualityFilter,
    this.sortOption = TorrentSortOption.seeds,
    this.isLoading = false,
    this.error,
  });

  TorrentSearchState copyWith({
    String? imdbId,
    int? season,
    int? episode,
    List<EztvTorrent>? torrents,
    List<EztvTorrent>? filteredTorrents,
    String? qualityFilter,
    TorrentSortOption? sortOption,
    bool? isLoading,
    String? error,
  }) {
    return TorrentSearchState(
      imdbId: imdbId ?? this.imdbId,
      season: season ?? this.season,
      episode: episode ?? this.episode,
      torrents: torrents ?? this.torrents,
      filteredTorrents: filteredTorrents ?? this.filteredTorrents,
      qualityFilter: qualityFilter,
      sortOption: sortOption ?? this.sortOption,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  Set<String> get availableQualities =>
      EztvApiService.getAvailableQualities(torrents);
}

enum TorrentSortOption { seeds, quality, size }

/// Notifier for torrent search with filtering and sorting
class TorrentSearchNotifier extends Notifier<TorrentSearchState> {
  @override
  TorrentSearchState build() {
    return const TorrentSearchState();
  }

  EztvApiService get _eztvService => ref.read(eztvApiServiceProvider);

  /// Search for torrents by IMDB ID
  Future<void> searchByImdbId(String imdbId) async {
    state = state.copyWith(
      imdbId: imdbId,
      isLoading: true,
      error: null,
      season: null,
      episode: null,
    );

    try {
      final torrents = await _eztvService.getTorrentsByImdbId(imdbId);
      state = state.copyWith(
        torrents: torrents,
        filteredTorrents: _applySortAndFilter(torrents),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  /// Search for torrents for a specific episode
  Future<void> searchForEpisode(
    String imdbId, {
    required int season,
    required int episode,
  }) async {
    state = state.copyWith(
      imdbId: imdbId,
      season: season,
      episode: episode,
      isLoading: true,
      error: null,
    );

    try {
      final torrents = await _eztvService.getTorrentsForEpisode(
        imdbId,
        season: season,
        episode: episode,
      );
      state = state.copyWith(
        torrents: torrents,
        filteredTorrents: _applySortAndFilter(torrents),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString(), isLoading: false);
    }
  }

  /// Set quality filter
  void setQualityFilter(String? quality) {
    state = state.copyWith(
      qualityFilter: quality,
      filteredTorrents: _applySortAndFilter(state.torrents, quality: quality),
    );
  }

  /// Set sort option
  void setSortOption(TorrentSortOption option) {
    state = state.copyWith(
      sortOption: option,
      filteredTorrents: _applySortAndFilter(state.torrents, sortOption: option),
    );
  }

  /// Apply sorting and filtering to torrents
  List<EztvTorrent> _applySortAndFilter(
    List<EztvTorrent> torrents, {
    String? quality,
    TorrentSortOption? sortOption,
  }) {
    var result = List<EztvTorrent>.from(torrents);
    final filterQuality = quality ?? state.qualityFilter;
    final sort = sortOption ?? state.sortOption;

    // Apply quality filter
    if (filterQuality != null) {
      result = EztvApiService.filterByQuality(result, filterQuality);
    }

    // Apply sorting
    switch (sort) {
      case TorrentSortOption.seeds:
        result = EztvApiService.sortBySeeds(result);
        break;
      case TorrentSortOption.quality:
        result = EztvApiService.sortByQuality(result);
        break;
      case TorrentSortOption.size:
        result = EztvApiService.sortBySize(result);
        break;
    }

    return result;
  }

  /// Clear search
  void clear() {
    state = const TorrentSearchState();
  }
}

/// Provider for TorrentSearchNotifier
final torrentSearchNotifierProvider =
    NotifierProvider<TorrentSearchNotifier, TorrentSearchState>(
      TorrentSearchNotifier.new,
    );

/// Notifier for torrent availability cache
class TorrentAvailabilityCacheNotifier
    extends Notifier<Map<String, Map<String, bool>>> {
  @override
  Map<String, Map<String, bool>> build() => {};

  void set(Map<String, Map<String, bool>> value) => state = value;

  void updateCache(String imdbId, Map<String, bool> availability) {
    state = {...state, imdbId: availability};
  }

  bool hasCache(String imdbId) => state.containsKey(imdbId);

  Map<String, bool>? getCache(String imdbId) => state[imdbId];
}

/// Cache for torrent availability per show
/// Maps IMDB ID to map of "S01E01" -> bool (has torrents)
final torrentAvailabilityCacheProvider =
    NotifierProvider<
      TorrentAvailabilityCacheNotifier,
      Map<String, Map<String, bool>>
    >(TorrentAvailabilityCacheNotifier.new);

/// Check and cache torrent availability for a show
final checkTorrentAvailabilityProvider =
    FutureProvider.family<Map<String, bool>, String>((ref, imdbId) async {
      final cacheNotifier = ref.read(torrentAvailabilityCacheProvider.notifier);
      if (cacheNotifier.hasCache(imdbId)) {
        return cacheNotifier.getCache(imdbId)!;
      }

      final eztvService = ref.read(eztvApiServiceProvider);
      final torrents = await eztvService.getTorrentsByImdbId(imdbId);

      final availability = <String, bool>{};
      for (final torrent in torrents) {
        if (torrent.season != null && torrent.episode != null) {
          final key =
              'S${torrent.season.toString().padLeft(2, '0')}E${torrent.episode.toString().padLeft(2, '0')}';
          availability[key] = true;
        }
      }

      // Update cache
      cacheNotifier.updateCache(imdbId, availability);

      return availability;
    });
