import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/torrentio_stream.dart';
import '../services/torrentio_api_service.dart';

/// Provider for Torrentio API service
final torrentioApiServiceProvider = Provider<TorrentioApiService>((ref) {
  return TorrentioApiService();
});

/// Get streams for a movie by IMDB ID
final movieStreamsProvider = FutureProvider.family<TorrentioResponse, String>((ref, imdbId) async {
  final torrentioService = ref.read(torrentioApiServiceProvider);
  return torrentioService.getMovieStreams(imdbId);
});

/// Get streams for a TV series episode
final seriesStreamsProvider = FutureProvider.family<TorrentioResponse,
    ({String imdbId, int season, int episode})>((ref, params) async {
  final torrentioService = ref.read(torrentioApiServiceProvider);
  return torrentioService.getSeriesStreams(
    params.imdbId,
    season: params.season,
    episode: params.episode,
  );
});

/// Get best stream for a movie
final bestMovieStreamProvider = FutureProvider.family<TorrentioStream?,
    ({String imdbId, String? preferredQuality})>((ref, params) async {
  final torrentioService = ref.read(torrentioApiServiceProvider);
  return torrentioService.getBestMovieStream(
    params.imdbId,
    preferredQuality: params.preferredQuality,
  );
});

/// Get best stream for an episode
final bestSeriesStreamProvider = FutureProvider.family<TorrentioStream?,
    ({String imdbId, int season, int episode, String? preferredQuality})>((ref, params) async {
  final torrentioService = ref.read(torrentioApiServiceProvider);
  return torrentioService.getBestSeriesStream(
    params.imdbId,
    season: params.season,
    episode: params.episode,
    preferredQuality: params.preferredQuality,
  );
});

/// Check if streams are available for a movie
final hasMovieStreamsProvider = FutureProvider.family<bool, String>((ref, imdbId) async {
  final response = await ref.watch(movieStreamsProvider(imdbId).future);
  return response.streams.isNotEmpty;
});

/// Check if streams are available for an episode
final hasSeriesStreamsProvider = FutureProvider.family<bool,
    ({String imdbId, int season, int episode})>((ref, params) async {
  final response = await ref.watch(seriesStreamsProvider(params).future);
  return response.streams.isNotEmpty;
});

/// State for stream selection/filtering
class StreamSearchState {
  final List<TorrentioStream> streams;
  final List<TorrentioStream> filteredStreams;
  final String? qualityFilter;
  final TorrentioSortOption sortOption;
  final bool isLoading;
  final String? error;

  const StreamSearchState({
    this.streams = const [],
    this.filteredStreams = const [],
    this.qualityFilter,
    this.sortOption = TorrentioSortOption.seeders,
    this.isLoading = false,
    this.error,
  });

  StreamSearchState copyWith({
    List<TorrentioStream>? streams,
    List<TorrentioStream>? filteredStreams,
    String? qualityFilter,
    TorrentioSortOption? sortOption,
    bool? isLoading,
    String? error,
  }) {
    return StreamSearchState(
      streams: streams ?? this.streams,
      filteredStreams: filteredStreams ?? this.filteredStreams,
      qualityFilter: qualityFilter,
      sortOption: sortOption ?? this.sortOption,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  Set<String> get availableQualities =>
      TorrentioApiService.getAvailableQualities(streams);
}

/// Notifier for stream search state
class StreamSearchNotifier extends Notifier<StreamSearchState> {
  @override
  StreamSearchState build() => const StreamSearchState();

  void setStreams(List<TorrentioStream> streams) {
    state = state.copyWith(
      streams: streams,
      filteredStreams: _applyFiltersAndSort(streams, state.qualityFilter, state.sortOption),
      isLoading: false,
      error: null,
    );
  }

  void setQualityFilter(String? quality) {
    state = state.copyWith(
      qualityFilter: quality,
      filteredStreams: _applyFiltersAndSort(state.streams, quality, state.sortOption),
    );
  }

  void setSortOption(TorrentioSortOption option) {
    state = state.copyWith(
      sortOption: option,
      filteredStreams: _applyFiltersAndSort(state.streams, state.qualityFilter, option),
    );
  }

  void setLoading(bool loading) {
    state = state.copyWith(isLoading: loading);
  }

  void setError(String? error) {
    state = state.copyWith(error: error, isLoading: false);
  }

  void clear() {
    state = const StreamSearchState();
  }

  List<TorrentioStream> _applyFiltersAndSort(
    List<TorrentioStream> streams,
    String? qualityFilter,
    TorrentioSortOption sortOption,
  ) {
    var filtered = streams;

    if (qualityFilter != null) {
      filtered = TorrentioApiService.filterByQuality(filtered, qualityFilter);
    }

    return TorrentioApiService.sortStreams(filtered, sortBy: sortOption);
  }
}

final streamSearchProvider = NotifierProvider<StreamSearchNotifier, StreamSearchState>(
  StreamSearchNotifier.new,
);
