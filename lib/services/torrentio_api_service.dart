import 'package:dio/dio.dart';
import '../models/torrentio_stream.dart';

/// Service for interacting with Torrentio Stremio addon API
class TorrentioApiService {
  static const String _defaultBaseUrl = 'https://torrentio.strem.fun';

  final Dio _dio;
  final String baseUrl;

  TorrentioApiService({String? baseUrl})
    : baseUrl = baseUrl ?? _defaultBaseUrl,
      _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl ?? _defaultBaseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'Mozilla/5.0 (compatible; TorrentClient/1.0)',
          },
        ),
      );

  /// Get the addon manifest
  Future<TorrentioManifest> getManifest() async {
    try {
      final response = await _dio.get('/manifest.json');
      return TorrentioManifest.fromJson(response.data);
    } on DioException catch (e) {
      throw TorrentioApiException('Failed to get manifest: ${e.message}');
    } catch (e) {
      throw TorrentioApiException('Failed to get manifest: $e');
    }
  }

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
      throw TorrentioApiException('Failed to get movie streams: ${e.message}');
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
      throw TorrentioApiException('Failed to get series streams: ${e.message}');
    } catch (e) {
      throw TorrentioApiException('Failed to get series streams: $e');
    }
  }

  /// Get best stream for a movie based on quality preference
  Future<TorrentioStream?> getBestMovieStream(
    String imdbId, {
    String? preferredQuality,
    int minSeeders = 1,
  }) async {
    final response = await getMovieStreams(imdbId);
    return _selectBestStream(
      response.streams,
      preferredQuality: preferredQuality,
      minSeeders: minSeeders,
    );
  }

  /// Get best stream for an episode based on quality preference
  Future<TorrentioStream?> getBestSeriesStream(
    String imdbId, {
    required int season,
    required int episode,
    String? preferredQuality,
    int minSeeders = 1,
  }) async {
    final response = await getSeriesStreams(
      imdbId,
      season: season,
      episode: episode,
    );
    return _selectBestStream(
      response.streams,
      preferredQuality: preferredQuality,
      minSeeders: minSeeders,
    );
  }

  /// Select best stream from a list based on quality and seeders
  TorrentioStream? _selectBestStream(
    List<TorrentioStream> streams, {
    String? preferredQuality,
    int minSeeders = 1,
  }) {
    if (streams.isEmpty) return null;

    // Filter by minimum seeders
    var filtered = streams.where((s) => s.seeders >= minSeeders).toList();
    if (filtered.isEmpty) {
      filtered = streams; // Fall back to all if none meet minimum
    }

    // If preferred quality specified, try to find it
    if (preferredQuality != null) {
      final qualityMatch = filtered
          .where(
            (s) => s.quality.toLowerCase() == preferredQuality.toLowerCase(),
          )
          .toList();
      if (qualityMatch.isNotEmpty) {
        // Sort by seeders and return best
        qualityMatch.sort((a, b) => b.seeders.compareTo(a.seeders));
        return qualityMatch.first;
      }
    }

    // Sort by quality priority, then by seeders
    filtered.sort((a, b) {
      final qualityCompare = b.qualityPriority.compareTo(a.qualityPriority);
      if (qualityCompare != 0) return qualityCompare;
      return b.seeders.compareTo(a.seeders);
    });

    return filtered.first;
  }

  /// Get available qualities from a list of streams
  static Set<String> getAvailableQualities(List<TorrentioStream> streams) {
    return streams.map((s) => s.quality).toSet();
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
    return streams.where((s) => s.quality == quality).toList();
  }
}

/// Sort options for Torrentio streams
enum TorrentioSortOption { seeders, quality, size, sizeDesc }

/// Torrentio addon manifest
class TorrentioManifest {
  final String id;
  final String version;
  final String name;
  final String description;
  final List<String> types;
  final List<TorrentioResource> resources;
  final String? background;
  final String? logo;

  TorrentioManifest({
    required this.id,
    required this.version,
    required this.name,
    required this.description,
    required this.types,
    required this.resources,
    this.background,
    this.logo,
  });

  factory TorrentioManifest.fromJson(Map<String, dynamic> json) {
    return TorrentioManifest(
      id: json['id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      types:
          (json['types'] as List<dynamic>?)
              ?.map((t) => t.toString())
              .toList() ??
          [],
      resources:
          (json['resources'] as List<dynamic>?)
              ?.map(
                (r) => TorrentioResource.fromJson(
                  r is Map<String, dynamic> ? r : {'name': r.toString()},
                ),
              )
              .toList() ??
          [],
      background: json['background'] as String?,
      logo: json['logo'] as String?,
    );
  }
}

/// Resource definition from manifest
class TorrentioResource {
  final String name;
  final List<String> types;
  final List<String> idPrefixes;

  TorrentioResource({
    required this.name,
    this.types = const [],
    this.idPrefixes = const [],
  });

  factory TorrentioResource.fromJson(Map<String, dynamic> json) {
    return TorrentioResource(
      name: json['name'] as String? ?? '',
      types:
          (json['types'] as List<dynamic>?)
              ?.map((t) => t.toString())
              .toList() ??
          [],
      idPrefixes:
          (json['idPrefixes'] as List<dynamic>?)
              ?.map((p) => p.toString())
              .toList() ??
          [],
    );
  }
}

/// Exception for Torrentio API errors
class TorrentioApiException implements Exception {
  final String message;
  TorrentioApiException(this.message);

  @override
  String toString() => 'TorrentioApiException: $message';
}
