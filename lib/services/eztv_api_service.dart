import 'package:dio/dio.dart';
import '../models/eztv_torrent.dart';

/// Service for interacting with EZTV API to get torrent links
class EztvApiService {
  static const String _baseUrl = 'https://eztvx.to/api';

  final Dio _dio;

  EztvApiService()
      : _dio = Dio(BaseOptions(
          baseUrl: _baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'Mozilla/5.0 (compatible; TorrentClient/1.0)',
          },
        ));

  /// Get torrents by IMDB ID
  /// IMDB ID should be in format "tt1234567" or just "1234567"
  Future<List<EztvTorrent>> getTorrentsByImdbId(String imdbId) async {
    try {
      // Clean up IMDB ID - remove 'tt' prefix if present
      final cleanId = imdbId.replaceAll('tt', '');

      final response = await _dio.get(
        '/get-torrents',
        queryParameters: {
          'imdb_id': cleanId,
          'limit': 100,
        },
      );

      if (response.data == null) return [];

      final torrents = response.data['torrents'];
      if (torrents == null || torrents is! List) return [];

      return (torrents)
          .map((json) => EztvTorrent.fromJson(json))
          .toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return []; // No torrents found
      }
      throw EztvApiException('Failed to get torrents: ${e.message}');
    } catch (e) {
      throw EztvApiException('Failed to get torrents: $e');
    }
  }

  /// Get torrents with pagination
  Future<EztvSearchResult> getTorrents({
    int page = 1,
    int limit = 30,
  }) async {
    try {
      final response = await _dio.get(
        '/get-torrents',
        queryParameters: {
          'page': page,
          'limit': limit,
        },
      );

      if (response.data == null) {
        return EztvSearchResult(torrents: [], totalCount: 0, page: page);
      }

      final torrents = response.data['torrents'];
      final totalCount = response.data['torrents_count'] as int? ?? 0;

      if (torrents == null || torrents is! List) {
        return EztvSearchResult(torrents: [], totalCount: totalCount, page: page);
      }

      final torrentList = (torrents)
          .map((json) => EztvTorrent.fromJson(json))
          .toList();

      return EztvSearchResult(
        torrents: torrentList,
        totalCount: totalCount,
        page: page,
      );
    } catch (e) {
      throw EztvApiException('Failed to get torrents: $e');
    }
  }

  /// Parse season and episode from filename using SXXEXX pattern
  static (int?, int?) _parseSeasonEpisodeFromFilename(String filename) {
    // Pattern: S01E02, s01e02, S1E2, etc.
    final regex = RegExp(r'[Ss](\d{1,2})[Ee](\d{1,2})');
    final match = regex.firstMatch(filename);
    if (match != null) {
      final season = int.tryParse(match.group(1) ?? '');
      final episode = int.tryParse(match.group(2) ?? '');
      return (season, episode);
    }
    return (null, null);
  }

  /// Search torrents for a specific show and filter by season/episode
  /// Uses both API fields and SXXEXX pattern matching in filename
  Future<List<EztvTorrent>> getTorrentsForEpisode(
    String imdbId, {
    int? season,
    int? episode,
  }) async {
    final allTorrents = await getTorrentsByImdbId(imdbId);

    if (season == null && episode == null) {
      return allTorrents;
    }

    return allTorrents.where((torrent) {
      // First try API-provided season/episode fields
      int? torrentSeason = torrent.season;
      int? torrentEpisode = torrent.episode;
      
      // If API fields are missing, parse from filename using SXXEXX pattern
      if (torrentSeason == null || torrentEpisode == null) {
        final (parsedSeason, parsedEpisode) = _parseSeasonEpisodeFromFilename(torrent.filename);
        torrentSeason ??= parsedSeason;
        torrentEpisode ??= parsedEpisode;
      }
      
      // Check if torrent matches the requested season/episode
      if (season != null && torrentSeason != season) return false;
      if (episode != null && torrentEpisode != episode) return false;
      return true;
    }).toList();
  }

  /// Get best torrent for an episode (highest seeds, best quality)
  Future<EztvTorrent?> getBestTorrentForEpisode(
    String imdbId, {
    required int season,
    required int episode,
    String? preferredQuality,
  }) async {
    final torrents = await getTorrentsForEpisode(
      imdbId,
      season: season,
      episode: episode,
    );

    if (torrents.isEmpty) return null;

    // Sort by quality and seeds
    torrents.sort((a, b) {
      // If preferred quality specified, prioritize it
      if (preferredQuality != null) {
        final aMatches = a.quality == preferredQuality;
        final bMatches = b.quality == preferredQuality;
        if (aMatches && !bMatches) return -1;
        if (!aMatches && bMatches) return 1;
      }

      // Then by quality priority
      final qualityCompare = b.qualityPriority.compareTo(a.qualityPriority);
      if (qualityCompare != 0) return qualityCompare;

      // Then by seeds
      return b.seeds.compareTo(a.seeds);
    });

    return torrents.first;
  }

  /// Filter torrents by quality
  static List<EztvTorrent> filterByQuality(
    List<EztvTorrent> torrents,
    String quality,
  ) {
    return torrents.where((t) => t.quality == quality).toList();
  }

  /// Sort torrents by seeds (descending)
  static List<EztvTorrent> sortBySeeds(List<EztvTorrent> torrents) {
    final sorted = List<EztvTorrent>.from(torrents);
    sorted.sort((a, b) => b.seeds.compareTo(a.seeds));
    return sorted;
  }

  /// Sort torrents by size (ascending)
  static List<EztvTorrent> sortBySize(
    List<EztvTorrent> torrents, {
    bool ascending = true,
  }) {
    final sorted = List<EztvTorrent>.from(torrents);
    sorted.sort((a, b) =>
        ascending ? a.sizeBytes.compareTo(b.sizeBytes) : b.sizeBytes.compareTo(a.sizeBytes));
    return sorted;
  }

  /// Sort torrents by quality priority (descending)
  static List<EztvTorrent> sortByQuality(List<EztvTorrent> torrents) {
    final sorted = List<EztvTorrent>.from(torrents);
    sorted.sort((a, b) => b.qualityPriority.compareTo(a.qualityPriority));
    return sorted;
  }

  /// Get available qualities from a list of torrents
  static Set<String> getAvailableQualities(List<EztvTorrent> torrents) {
    return torrents.map((t) => t.quality).toSet();
  }

  /// Group torrents by season
  static Map<int, List<EztvTorrent>> groupBySeason(List<EztvTorrent> torrents) {
    final Map<int, List<EztvTorrent>> grouped = {};
    for (final torrent in torrents) {
      if (torrent.season != null) {
        grouped.putIfAbsent(torrent.season!, () => []).add(torrent);
      }
    }
    return grouped;
  }

  /// Group torrents by episode (within a season)
  static Map<int, List<EztvTorrent>> groupByEpisode(List<EztvTorrent> torrents) {
    final Map<int, List<EztvTorrent>> grouped = {};
    for (final torrent in torrents) {
      if (torrent.episode != null) {
        grouped.putIfAbsent(torrent.episode!, () => []).add(torrent);
      }
    }
    return grouped;
  }
}

/// Result from EZTV search with pagination info
class EztvSearchResult {
  final List<EztvTorrent> torrents;
  final int totalCount;
  final int page;

  EztvSearchResult({
    required this.torrents,
    required this.totalCount,
    required this.page,
  });

  bool get hasMore => torrents.length < totalCount;
  int get totalPages => (totalCount / 30).ceil();
}

/// Exception for EZTV API errors
class EztvApiException implements Exception {
  final String message;
  EztvApiException(this.message);

  @override
  String toString() => 'EztvApiException: $message';
}
