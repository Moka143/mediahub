import 'content_provider.dart';
import 'eztv_api_service.dart';

/// EZTV content provider implementation
class EztvContentProvider implements ContentProvider {
  final EztvApiService _apiService;
  bool _isEnabled;

  EztvContentProvider({
    EztvApiService? apiService,
    bool isEnabled = true,
  })  : _apiService = apiService ?? EztvApiService(),
        _isEnabled = isEnabled;

  @override
  String get id => 'eztv';

  @override
  String get name => 'EZTV';

  @override
  String get description => 'TV shows torrent provider specializing in TV series';

  @override
  String? get iconUrl => null;

  @override
  bool get isEnabled => _isEnabled;

  set isEnabled(bool value) => _isEnabled = value;

  @override
  int get priority => 100; // High priority as it's our main provider

  @override
  Future<List<StreamSource>> search(String query) async {
    // EZTV doesn't support free-text search, only IMDB ID lookup
    // Return empty for now, but could implement scraping in the future
    return [];
  }

  @override
  Future<List<StreamSource>> getStreamsForEpisode({
    required String imdbId,
    required int season,
    required int episode,
  }) async {
    try {
      final torrents = await _apiService.getTorrentsForEpisode(
        imdbId,
        season: season,
        episode: episode,
      );

      return torrents
          .map((t) => StreamSource.fromEztv(t))
          .toList();
    } catch (e) {
      print('EZTV error: $e');
      return [];
    }
  }

  @override
  Future<List<StreamSource>> getStreamsForShow({
    required String imdbId,
  }) async {
    try {
      final torrents = await _apiService.getTorrentsByImdbId(imdbId);

      return torrents
          .map((t) => StreamSource.fromEztv(t))
          .toList();
    } catch (e) {
      print('EZTV error: $e');
      return [];
    }
  }
}
