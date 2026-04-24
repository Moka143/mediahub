import 'dart:async';

import '../models/episode.dart';
import '../models/eztv_torrent.dart';
import '../models/local_media_file.dart';
import 'eztv_api_service.dart';
import 'qbittorrent_api_service.dart';
import 'tmdb_api_service.dart';
import 'torrentio_api_service.dart';

/// Represents the status of an episode for auto-download tracking
enum EpisodeDownloadStatus {
  /// Episode is not yet available according to TMDB
  notAired,
  /// Episode has aired but no torrent found yet
  awaitingTorrent,
  /// Torrent available but not downloaded
  available,
  /// Currently downloading
  downloading,
  /// Downloaded and ready to watch
  downloaded,
  /// Episode watched
  watched,
}

/// Tracks episode information for auto-download
class EpisodeTrackingInfo {
  final int showId;
  final String? imdbId;
  final String showName;
  final int season;
  final int episode;
  final String? airDate;
  final EpisodeDownloadStatus status;
  final String? quality;
  final String? torrentHash;
  final String? magnetLink;

  EpisodeTrackingInfo({
    required this.showId,
    this.imdbId,
    required this.showName,
    required this.season,
    required this.episode,
    this.airDate,
    required this.status,
    this.quality,
    this.torrentHash,
    this.magnetLink,
  });

  String get episodeCode {
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }

  EpisodeTrackingInfo copyWith({
    int? showId,
    String? imdbId,
    String? showName,
    int? season,
    int? episode,
    String? airDate,
    EpisodeDownloadStatus? status,
    String? quality,
    String? torrentHash,
    String? magnetLink,
  }) {
    return EpisodeTrackingInfo(
      showId: showId ?? this.showId,
      imdbId: imdbId ?? this.imdbId,
      showName: showName ?? this.showName,
      season: season ?? this.season,
      episode: episode ?? this.episode,
      airDate: airDate ?? this.airDate,
      status: status ?? this.status,
      quality: quality ?? this.quality,
      torrentHash: torrentHash ?? this.torrentHash,
      magnetLink: magnetLink ?? this.magnetLink,
    );
  }

  Map<String, dynamic> toJson() => {
    'show_id': showId,
    'imdb_id': imdbId,
    'show_name': showName,
    'season': season,
    'episode': episode,
    'air_date': airDate,
    'status': status.index,
    'quality': quality,
    'torrent_hash': torrentHash,
    'magnet_link': magnetLink,
  };

  factory EpisodeTrackingInfo.fromJson(Map<String, dynamic> json) {
    return EpisodeTrackingInfo(
      showId: json['show_id'] as int,
      imdbId: json['imdb_id'] as String?,
      showName: json['show_name'] as String,
      season: json['season'] as int,
      episode: json['episode'] as int,
      airDate: json['air_date'] as String?,
      status: EpisodeDownloadStatus.values[json['status'] as int? ?? 0],
      quality: json['quality'] as String?,
      torrentHash: json['torrent_hash'] as String?,
      magnetLink: json['magnet_link'] as String?,
    );
  }
}

/// Result of next episode lookup
class NextEpisodeResult {
  final Episode? nextEpisode;
  final bool isSeasonEnd;
  final bool isSeriesEnd;
  final bool isNextSeasonAvailable;
  final int? nextSeasonNumber;
  final String? message;

  NextEpisodeResult({
    this.nextEpisode,
    this.isSeasonEnd = false,
    this.isSeriesEnd = false,
    this.isNextSeasonAvailable = false,
    this.nextSeasonNumber,
    this.message,
  });

  bool get hasNextEpisode => nextEpisode != null;
}

/// Service for managing auto-download of next episodes
class AutoDownloadService {
  final TmdbApiService _tmdbService;
  final EztvApiService _eztvService;
  final QBittorrentApiService _qbtService;
  final TorrentioApiService _torrentioService;

  AutoDownloadService({
    required TmdbApiService tmdbService,
    required EztvApiService eztvService,
    required QBittorrentApiService qbtService,
    required TorrentioApiService torrentioService,
  })  : _tmdbService = tmdbService,
        _eztvService = eztvService,
        _qbtService = qbtService,
        _torrentioService = torrentioService;

  /// Detect quality from a torrent filename or current download
  String detectQualityFromFilename(String filename) {
    final lower = filename.toLowerCase();
    if (lower.contains('2160p') || lower.contains('4k') || lower.contains('uhd')) {
      return '4K';
    }
    if (lower.contains('1080p')) return '1080p';
    if (lower.contains('720p')) return '720p';
    if (lower.contains('480p')) return '480p';
    if (lower.contains('web-dl') || lower.contains('webdl')) return 'WEB-DL';
    if (lower.contains('webrip')) return 'WEBRip';
    if (lower.contains('hdtv')) return 'HDTV';
    if (lower.contains('bluray') || lower.contains('bdrip')) return 'BluRay';
    return 'Unknown';
  }

  /// Get the next episode for a show after the given season/episode
  Future<NextEpisodeResult> getNextEpisode({
    required int showId,
    required int currentSeason,
    required int currentEpisode,
  }) async {
    try {
      final show = await _tmdbService.getShowDetails(showId);
      final totalSeasons = show.numberOfSeasons ?? 0;

      // Try to get current season episodes
      final currentSeasonEpisodes = await _tmdbService.getSeasonEpisodes(
        showId,
        currentSeason,
      );

      // Check if there's a next episode in current season
      final nextEpNum = currentEpisode + 1;
      final nextInSeason = currentSeasonEpisodes
          .where((e) => e.episodeNumber == nextEpNum)
          .firstOrNull;

      if (nextInSeason != null) {
        // Check if it has aired
        final hasAired = _hasEpisodeAired(nextInSeason.airDate);
        return NextEpisodeResult(
          nextEpisode: nextInSeason,
          isSeasonEnd: false,
          isSeriesEnd: false,
          message: hasAired ? null : 'Next episode airs on ${nextInSeason.airDate}',
        );
      }

      // No more episodes in current season - check next season
      final isSeasonEnd = true;
      
      if (currentSeason >= totalSeasons) {
        // This was the last season
        return NextEpisodeResult(
          isSeasonEnd: true,
          isSeriesEnd: true,
          message: 'Series ended - no more seasons available',
        );
      }

      // Try to get next season's first episode
      final nextSeason = currentSeason + 1;
      try {
        final nextSeasonEpisodes = await _tmdbService.getSeasonEpisodes(
          showId,
          nextSeason,
        );

        if (nextSeasonEpisodes.isNotEmpty) {
          final firstEp = nextSeasonEpisodes.first;
          final hasAired = _hasEpisodeAired(firstEp.airDate);
          
          return NextEpisodeResult(
            nextEpisode: firstEp,
            isSeasonEnd: isSeasonEnd,
            isSeriesEnd: false,
            isNextSeasonAvailable: hasAired,
            nextSeasonNumber: nextSeason,
            message: hasAired 
                ? 'Moving to Season $nextSeason' 
                : 'Season $nextSeason Episode 1 airs on ${firstEp.airDate}',
          );
        }
      } catch (e) {
        // Next season might not have episodes yet
      }

      return NextEpisodeResult(
        isSeasonEnd: true,
        isSeriesEnd: false,
        isNextSeasonAvailable: false,
        nextSeasonNumber: nextSeason,
        message: 'Season $nextSeason not yet available',
      );
    } catch (e) {
      return NextEpisodeResult(
        message: 'Failed to fetch next episode: $e',
      );
    }
  }

  /// Check if an episode is already downloaded
  bool isEpisodeDownloaded({
    required List<LocalMediaFile> downloadedFiles,
    required String showName,
    required int season,
    required int episode,
  }) {
    final targetCode = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    
    return downloadedFiles.any((file) {
      // Match by show name (case-insensitive) and episode code
      final fileShowName = file.showName?.toLowerCase() ?? '';
      final targetShowName = showName.toLowerCase();
      
      // Fuzzy match show name (handle slight variations)
      final showMatches = fileShowName.contains(targetShowName) || 
          targetShowName.contains(fileShowName) ||
          _normalizeShowName(fileShowName) == _normalizeShowName(targetShowName);
      
      return showMatches && file.episodeCode == targetCode;
    });
  }

  /// Normalize show name for comparison
  String _normalizeShowName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .replaceAll('the', '');
  }

  /// Maximum file size for streaming (900 MB) - smaller files buffer faster
  static const int maxStreamingSizeBytes = 900 * 1024 * 1024; // 900 MB

  /// Find the best matching torrent for an episode with quality preference
  /// Tries EZTV first, then falls back to Torrentio if no results found
  /// For streaming, filters to files under 900 MB for faster buffering
  Future<EztvTorrent?> findTorrentForEpisode({
    required String imdbId,
    required int season,
    required int episode,
    String? preferredQuality,
    bool forStreaming = true,
  }) async {
    final maxSize = forStreaming ? maxStreamingSizeBytes : null;
    final episodeCode = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    print('[AutoDownload] Looking for $episodeCode (IMDB: $imdbId, quality: $preferredQuality, streaming: $forStreaming)');
    
    // Try EZTV first
    try {
      final allEztvTorrents = await _eztvService.getTorrentsForEpisode(
        imdbId,
        season: season,
        episode: episode,
      );
      print('[AutoDownload] EZTV returned ${allEztvTorrents.length} torrents for $episodeCode');
      
      // Filter by size if streaming (but keep torrents with unknown size = 0)
      var eztvTorrents = allEztvTorrents;
      if (maxSize != null && allEztvTorrents.isNotEmpty) {
        // First try to find torrents under the size limit
        final underLimit = allEztvTorrents.where((t) => 
          t.sizeBytes > 0 && t.sizeBytes <= maxSize
        ).toList();
        
        // If no torrents under limit, use all torrents with unknown size (0) as fallback
        if (underLimit.isEmpty) {
          final unknownSize = allEztvTorrents.where((t) => t.sizeBytes == 0).toList();
          if (unknownSize.isNotEmpty) {
            print('[AutoDownload] EZTV: No torrents under ${maxSize ~/ (1024 * 1024)}MB, using ${unknownSize.length} with unknown size');
            eztvTorrents = unknownSize;
          } else {
            print('[AutoDownload] EZTV: All ${allEztvTorrents.length} torrents exceed ${maxSize ~/ (1024 * 1024)}MB limit');
            eztvTorrents = [];
          }
        } else {
          print('[AutoDownload] EZTV: ${underLimit.length}/${allEztvTorrents.length} under ${maxSize ~/ (1024 * 1024)}MB');
          eztvTorrents = underLimit;
        }
      }
      
      if (eztvTorrents.isNotEmpty) {
        // Sort by quality and seeds
        eztvTorrents.sort((a, b) {
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
        
        final result = eztvTorrents.first;
        print('[AutoDownload] Found torrent via EZTV: ${result.title} (${result.sizeBytes ~/ (1024 * 1024)}MB)');
        return result;
      }
    } catch (e) {
      print('[AutoDownload] EZTV lookup failed: $e');
    }
    
    // Fall back to Torrentio (only if EZTV found nothing)
    print('[AutoDownload] EZTV found no suitable torrents, trying Torrentio for $episodeCode...');
    try {
      final response = await _torrentioService.getSeriesStreams(
        imdbId,
        season: season,
        episode: episode,
      );
      print('[AutoDownload] Torrentio returned ${response.streams.length} streams');
      
      // Filter by size if streaming
      var streams = response.streams;
      if (maxSize != null && streams.isNotEmpty) {
        // First try torrents with known size under limit
        final underLimit = streams.where((s) => 
          s.sizeBytes > 0 && s.sizeBytes <= maxSize
        ).toList();
        
        if (underLimit.isNotEmpty) {
          print('[AutoDownload] Torrentio: ${underLimit.length}/${streams.length} under ${maxSize ~/ (1024 * 1024)}MB');
          streams = underLimit;
        } else {
          // Fallback: use streams with unknown size (sizeBytes == 0)
          final unknownSize = streams.where((s) => s.sizeBytes == 0).toList();
          if (unknownSize.isNotEmpty) {
            print('[AutoDownload] Torrentio: No streams under limit, using ${unknownSize.length} with unknown size');
            streams = unknownSize;
          } else {
            print('[AutoDownload] Torrentio: All ${streams.length} streams exceed ${maxSize ~/ (1024 * 1024)}MB limit');
            // Don't filter - use smallest available
          }
        }
      }
      
      if (streams.isEmpty) {
        print('[AutoDownload] No Torrentio streams found');
        return null;
      }
      
      // Use the streaming score to get the best stream for downloading
      // This prioritizes single-episode torrents (including those with subs) over season packs
      // and considers quality and seeders
      final singleEpisodeTorrents = streams.where((s) => s.isSingleEpisodeRelease).toList();
      final seasonPacks = streams.where((s) => s.isSeasonPack).toList();
      
      print('[AutoDownload] Torrentio: ${singleEpisodeTorrents.length} single-episode releases, ${seasonPacks.length} season packs');
      
      // Prefer single-episode torrents over season packs
      var preferredStreams = singleEpisodeTorrents.isNotEmpty ? singleEpisodeTorrents : seasonPacks;
      
      // Sort by quality and seeders, respecting preferred quality if set
      preferredStreams.sort((a, b) {
        if (preferredQuality != null) {
          final aMatches = a.quality.toLowerCase() == preferredQuality.toLowerCase();
          final bMatches = b.quality.toLowerCase() == preferredQuality.toLowerCase();
          if (aMatches && !bMatches) return -1;
          if (!aMatches && bMatches) return 1;
        }
        // Use streaming score for overall comparison
        return b.streamingScore.compareTo(a.streamingScore);
      });
      
      final torrentioStream = preferredStreams.first;
      final isSeasonPack = torrentioStream.isSeasonPack;
      
      if (torrentioStream.magnetUri.isNotEmpty) {
        print('[AutoDownload] Found torrent via Torrentio${isSeasonPack ? ' (SEASON PACK - will select file)' : ' (single episode)'}:');
        print('[AutoDownload]   Title: ${torrentioStream.title}');
        print('[AutoDownload]   Size: ${(torrentioStream.sizeBytes) ~/ (1024 * 1024)}MB');
        print('[AutoDownload]   Hash: ${torrentioStream.infoHash}');
        print('[AutoDownload]   FileIdx: ${torrentioStream.fileIdx}');
        print('[AutoDownload]   Filename: ${torrentioStream.filename}');
        print('[AutoDownload]   Is single file: ${torrentioStream.isSingleFile}');
        print('[AutoDownload]   Streaming score: ${torrentioStream.streamingScore}');
        
        // Convert TorrentioStream to EztvTorrent for compatibility
        return EztvTorrent(
          id: 0,
          hash: torrentioStream.infoHash,
          filename: torrentioStream.filename ?? torrentioStream.title,
          title: torrentioStream.title,
          magnetUrl: torrentioStream.magnetUri,
          sizeBytes: torrentioStream.sizeBytes,
          seeds: torrentioStream.seeders,
          peers: 0,
          season: season,
          episode: episode,
          imdbId: imdbId,
          fileIdx: torrentioStream.fileIdx, // Pass fileIdx for season pack handling
        );
      }
    } catch (e) {
      print('[AutoDownload] Torrentio lookup failed: $e');
    }
    
    print('[AutoDownload] No torrent found for $imdbId S${season}E$episode');
    return null;
  }

  /// Download the next episode automatically
  /// If fileIdx is provided (from Torrentio season pack), only that file will be downloaded
  Future<bool> downloadNextEpisode({
    required String magnetLink,
    String? savePath,
    String? infoHash,
    int? fileIdx,
  }) async {
    try {
      print('[AutoDownload] downloadNextEpisode called - infoHash: $infoHash, fileIdx: $fileIdx');
      
      final success = await _qbtService.addTorrent(
        magnetLink: magnetLink,
        savePath: savePath,
        sequentialDownload: true, // Enable sequential for faster playback
        firstLastPiecePrio: true,
      );
      
      print('[AutoDownload] Torrent added: $success');
      
      // If this is a multi-file torrent (season pack), select only the specific file
      if (success && fileIdx != null && infoHash != null && infoHash.isNotEmpty) {
        print('[AutoDownload] Season pack detected, selecting only file index $fileIdx (hash: $infoHash)');
        // Wait a moment for torrent to be added and files to be parsed
        await Future.delayed(const Duration(milliseconds: 2000));
        
        try {
          // Get the file list to find total files
          final files = await _qbtService.getTorrentFiles(infoHash);
          print('[AutoDownload] Torrent has ${files.length} files');
          
          if (files.isNotEmpty) {
            // Log all files for debugging
            for (int i = 0; i < files.length; i++) {
              print('[AutoDownload] File $i: ${files[i].name}');
            }
            
            // Set all files to "do not download" (priority 0)
            final allFileIds = List.generate(files.length, (i) => i);
            await _qbtService.setFilePriority(infoHash, allFileIds, 0);
            print('[AutoDownload] Set all ${files.length} files to priority 0 (skip)');
            
            // Set the specific file to normal priority (1) or high (6)
            if (fileIdx >= 0 && fileIdx < files.length) {
              await _qbtService.setFilePriority(infoHash, [fileIdx], 6);
              print('[AutoDownload] Selected file $fileIdx: ${files[fileIdx].name} (priority 6)');
            } else {
              print('[AutoDownload] WARNING: fileIdx $fileIdx is out of range (0-${files.length - 1})');
            }
          } else {
            print('[AutoDownload] WARNING: No files found in torrent yet');
          }
        } catch (e) {
          print('[AutoDownload] Failed to select specific file: $e');
          // Continue anyway - torrent was added successfully
        }
      } else {
        if (fileIdx == null) print('[AutoDownload] No fileIdx provided - downloading all files');
        if (infoHash == null || infoHash.isEmpty) print('[AutoDownload] No infoHash provided');
      }
      
      return success;
    } catch (e) {
      print('Error downloading next episode: $e');
      return false;
    }
  }

  /// Check if episode has aired based on air date
  bool _hasEpisodeAired(String? airDate) {
    if (airDate == null) return false;
    try {
      final date = DateTime.parse(airDate);
      return date.isBefore(DateTime.now());
    } catch (e) {
      return false;
    }
  }

  /// Get all available torrents for an episode with different qualities
  Future<List<EztvTorrent>> getAvailableTorrentsForEpisode({
    required String imdbId,
    required int season,
    required int episode,
  }) async {
    try {
      final torrents = await _eztvService.getTorrentsForEpisode(
        imdbId,
        season: season,
        episode: episode,
      );
      
      // Sort by quality priority and seeds
      torrents.sort((a, b) {
        final qualityCompare = b.qualityPriority.compareTo(a.qualityPriority);
        if (qualityCompare != 0) return qualityCompare;
        return b.seeds.compareTo(a.seeds);
      });
      
      return torrents;
    } catch (e) {
      return [];
    }
  }

  /// Check if a torrent is currently downloading in qBittorrent
  Future<bool> isEpisodeCurrentlyDownloading({
    required String showName,
    required int season,
    required int episode,
  }) async {
    try {
      final torrents = await _qbtService.getTorrents();
      final episodeCode = 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'.toLowerCase();
      
      return torrents.any((torrent) {
        final name = torrent.name.toLowerCase();
        final showMatch = name.contains(showName.toLowerCase().replaceAll(' ', '.')) ||
            name.contains(showName.toLowerCase().replaceAll(' ', '-'));
        return showMatch && name.contains(episodeCode.toLowerCase());
      });
    } catch (e) {
      return false;
    }
  }
}
