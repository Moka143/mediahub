import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/eztv_torrent.dart';
import '../utils/error_messages.dart';
import '../utils/media_names.dart';
import 'http_client.dart';

/// Service for interacting with EZTV API to get torrent links
class EztvApiService {
  static const String _baseUrl = 'https://eztvx.to/api';

  final Dio _dio;

  /// A short connect timeout and **no retries**, unlike the other indexers.
  ///
  /// EZTV sits on a domain that is regularly blocked or blackholed. With the
  /// shared defaults — a 15 s connect timeout repeated by two retries — a
  /// dead domain cost ~46 s of "Finding torrent…" before Torrentio was even
  /// asked. A reachable EZTV connects in well under a second; one that has
  /// not connected in five is not going to.
  EztvApiService()
    : _dio = buildJsonDio(
        baseUrl: _baseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 12),
        headers: {'User-Agent': 'Mozilla/5.0 (compatible; TorrentClient/1.0)'},
        maxRetries: 0,
      );

  /// Get torrents by IMDB ID
  /// IMDB ID should be in format "tt1234567" or just "1234567"
  Future<List<EztvTorrent>> getTorrentsByImdbId(String imdbId) async {
    try {
      // Clean up IMDB ID - remove 'tt' prefix if present
      final cleanId = imdbId.replaceAll('tt', '');

      final response = await _dio.get(
        '/get-torrents',
        queryParameters: {'imdb_id': cleanId, 'limit': 100},
      );

      if (response.data == null) return [];

      final torrents = response.data['torrents'];
      if (torrents == null || torrents is! List) return [];

      return (torrents).map((json) => EztvTorrent.fromJson(json)).toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return []; // No torrents found
      }
      throw EztvApiException.fromDio(e);
    } catch (e) {
      throw EztvApiException('Failed to get torrents: $e');
    }
  }

  /// The torrents in [all] that are [season]x[episode].
  ///
  /// The API's own season/episode fields win when present; otherwise the
  /// filename is read with the shared parser, so `S01E105` is episode 105
  /// here as everywhere else (this used to stop at two digits and call it
  /// episode 10).
  @visibleForTesting
  static List<EztvTorrent> filterForEpisode(
    List<EztvTorrent> all, {
    int? season,
    int? episode,
  }) {
    if (season == null && episode == null) return all;
    return all.where((torrent) {
      var torrentSeason = torrent.season;
      var torrentEpisode = torrent.episode;
      if (torrentSeason == null || torrentEpisode == null) {
        final parsed = parseEpisodeCode(torrent.filename);
        torrentSeason ??= parsed?.season;
        torrentEpisode ??= parsed?.episode;
      }
      if (season != null && torrentSeason != season) return false;
      if (episode != null && torrentEpisode != episode) return false;
      return true;
    }).toList();
  }

  /// Search torrents for a specific show and filter by season/episode
  Future<List<EztvTorrent>> getTorrentsForEpisode(
    String imdbId, {
    int? season,
    int? episode,
  }) async {
    final allTorrents = await getTorrentsByImdbId(imdbId);
    return filterForEpisode(allTorrents, season: season, episode: episode);
  }
}

/// Exception for EZTV API errors
class EztvApiException extends HttpServiceException {
  EztvApiException(
    super.message, {
    super.statusCode,
    super.isNetwork,
    super.isTimeout,
  });

  EztvApiException.fromDio(DioException e)
    : super.fromDio(
        'Failed to get torrents: ${e.response?.statusCode ?? e.type.name}',
        e,
      );

  @override
  String get kind => 'EztvApiException';
}
