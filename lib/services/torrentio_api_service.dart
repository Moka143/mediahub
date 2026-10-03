import 'package:dio/dio.dart';

import '../models/torrentio_stream.dart';
import '../utils/error_messages.dart';
import '../utils/media_quality.dart';
import 'http_client.dart';

/// Service for interacting with Torrentio Stremio addon API
class TorrentioApiService {
  static const String _baseUrl = 'https://torrentio.strem.fun';

  final Dio _dio;

  TorrentioApiService()
    : _dio = buildJsonDio(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'User-Agent': 'Mozilla/5.0 (compatible; TorrentClient/1.0)'},
      );

  /// Get streams for a movie by IMDB ID
  ///
  /// [imdbId] should be in format "tt1234567"
  Future<TorrentioResponse> getMovieStreams(String imdbId) async {
    try {
      // Ensure IMDB ID has 'tt' prefix
      final cleanId = imdbId.startsWith('tt') ? imdbId : 'tt$imdbId';

      final response = await _dio.get('/stream/movie/$cleanId.json');

      if (response.data == null) {
        return TorrentioResponse(streams: []);
      }

      return TorrentioResponse.fromJson(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return TorrentioResponse(streams: []); // No streams found
      }
      throw TorrentioApiException.fromDio('movie streams', e);
    } catch (e) {
      throw TorrentioApiException('Failed to get movie streams: $e');
    }
  }

  /// Get streams for a TV series episode
  ///
  /// [imdbId] should be the show's IMDB ID in format "tt1234567"
  /// [season] and [episode] are 1-indexed
  Future<TorrentioResponse> getSeriesStreams(
    String imdbId, {
    required int season,
    required int episode,
  }) async {
    try {
      // Ensure IMDB ID has 'tt' prefix
      final cleanId = imdbId.startsWith('tt') ? imdbId : 'tt$imdbId';

      // Stremio format: {imdb}:{season}:{episode}
      final videoId = '$cleanId:$season:$episode';

      final response = await _dio.get('/stream/series/$videoId.json');

      if (response.data == null) {
        return TorrentioResponse(streams: []);
      }

      return TorrentioResponse.fromJson(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return TorrentioResponse(streams: []); // No streams found
      }
      throw TorrentioApiException.fromDio('series streams', e);
    } catch (e) {
      throw TorrentioApiException('Failed to get series streams: $e');
    }
  }

  /// Sort streams by various criteria, with EZTV prioritized first for TV shows
  static List<TorrentioStream> sortStreams(
    List<TorrentioStream> streams, {
    TorrentioSortOption sortBy = TorrentioSortOption.seeders,
    bool prioritizeEztv = true,
  }) {
    final sorted = List<TorrentioStream>.from(streams);

    // Primary sort by criteria
    switch (sortBy) {
      case TorrentioSortOption.seeders:
        sorted.sort((a, b) => b.seeders.compareTo(a.seeders));
        break;
      case TorrentioSortOption.quality:
        sorted.sort((a, b) => b.qualityPriority.compareTo(a.qualityPriority));
        break;
      case TorrentioSortOption.size:
        sorted.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
        break;
      case TorrentioSortOption.sizeDesc:
        sorted.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
        break;
    }

    // If prioritizing EZTV, stable sort to move EZTV to the top while preserving order within groups
    if (prioritizeEztv) {
      sorted.sort((a, b) {
        final aIsEztv = a.sourceSite.toLowerCase() == 'eztv';
        final bIsEztv = b.sourceSite.toLowerCase() == 'eztv';

        // EZTV comes first
        if (aIsEztv && !bIsEztv) return -1;
        if (!aIsEztv && bIsEztv) return 1;

        // Within same provider group, apply the original sort criteria
        switch (sortBy) {
          case TorrentioSortOption.seeders:
            return b.seeders.compareTo(a.seeders);
          case TorrentioSortOption.quality:
            return b.qualityPriority.compareTo(a.qualityPriority);
          case TorrentioSortOption.size:
            return a.sizeBytes.compareTo(b.sizeBytes);
          case TorrentioSortOption.sizeDesc:
            return b.sizeBytes.compareTo(a.sizeBytes);
        }
      });
    }

    return sorted;
  }

  /// Filter streams by quality
  static List<TorrentioStream> filterByQuality(
    List<TorrentioStream> streams,
    String quality,
  ) {
    return streams.where((s) => qualityMatches(s.quality, quality)).toList();
  }
}

/// Sort options for Torrentio streams
enum TorrentioSortOption { seeders, quality, size, sizeDesc }

/// Exception for Torrentio API errors
class TorrentioApiException extends HttpServiceException {
  TorrentioApiException(
    super.message, {
    super.statusCode,
    super.isNetwork,
    super.isTimeout,
  });

  TorrentioApiException.fromDio(String what, DioException e)
    : super.fromDio(
        'Failed to get $what: ${e.response?.statusCode ?? e.type.name}',
        e,
      );

  @override
  String get kind => 'TorrentioApiException';
}
