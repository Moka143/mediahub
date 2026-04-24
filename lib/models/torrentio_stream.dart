/// Represents a stream from Torrentio addon
/// 
/// Key concepts from Stremio/Torrentio:
/// - `fileIdx`: When present, indicates this is a multi-file torrent
///   and this is the specific file index to play. When null, it's a single-file torrent.
/// - `filename`: The specific filename within a multi-file torrent (from behaviorHints)
/// - `bingeGroup`: Used by Stremio to group related streams for binge-watching
/// 
/// IMPORTANT: A torrent with video + subtitle files will have fileIdx set, but
/// it's NOT a season pack. We detect true season packs by looking for pack
/// indicators in the title (Complete, Pack, S01, Season, etc. without episode number).
/// 
/// For streaming, single-file/single-episode torrents are preferred as they don't 
/// require downloading an entire season pack just to play one episode.
class TorrentioStream {
  final String name;
  final String title;
  final String infoHash;
  final int? fileIdx;
  final String? bingeGroup;
  final String? filename;
  final List<String> sources;

  TorrentioStream({
    required this.name,
    required this.title,
    required this.infoHash,
    this.fileIdx,
    this.bingeGroup,
    this.filename,
    this.sources = const [],
  });

  factory TorrentioStream.fromJson(Map<String, dynamic> json) {
    final behaviorHints = json['behaviorHints'] as Map<String, dynamic>?;
    
    return TorrentioStream(
      name: json['name'] as String? ?? '',
      title: json['title'] as String? ?? '',
      infoHash: json['infoHash'] as String? ?? '',
      fileIdx: json['fileIdx'] as int?,
      bingeGroup: behaviorHints?['bingeGroup'] as String?,
      filename: behaviorHints?['filename'] as String?,
      sources: (json['sources'] as List<dynamic>?)
              ?.map((s) => s.toString())
              .toList() ??
          [],
    );
  }
  
  /// Whether this stream is from a single-file torrent (preferred for streaming)
  /// 
  /// Single-file torrents have fileIdx = null because there's only one file.
  /// Season packs/collections have fileIdx set to specify which file to play.
  /// 
  /// Based on Torrentio's logic: when fileIdx is an integer, it's a multi-file
  /// torrent where that specific file index should be played.
  bool get isSingleFile => fileIdx == null;
  
  /// Whether this stream is from a TRUE season pack (multiple episodes)
  /// 
  /// A multi-file torrent (fileIdx != null) could be:
  /// 1. A true season pack (Complete Season, S01 Pack, etc.)
  /// 2. A single episode with extras (video + SRT, sample, nfo files)
  /// 
  /// We detect true season packs by looking for pack indicators AND
  /// absence of specific episode markers in a way that suggests a pack.
  bool get isSeasonPack {
    if (fileIdx == null) return false; // Single file, not a pack
    
    // Check if this is a true season pack vs just a release with subtitles
    return _isTrueSeasonPack;
  }
  
  /// Whether this is a single episode release (even if multi-file with subs)
  /// 
  /// A release with video + subtitles should be treated as a single episode,
  /// not penalized as a "season pack".
  bool get isSingleEpisodeRelease {
    if (fileIdx == null) return true; // True single file
    
    // Multi-file but NOT a season pack = single episode with extras (subs, etc.)
    return !_isTrueSeasonPack;
  }
  
  /// Internal check for true season pack indicators
  bool get _isTrueSeasonPack {
    final titleLower = title.toLowerCase();
    final releaseLower = releaseName.toLowerCase();
    final filenameLower = (filename ?? '').toLowerCase();
    
    // Common season pack indicators
    final packIndicators = [
      'complete',
      'season pack',
      'full season',
      's01-s', // S01-S02, etc.
      'seasons',
      'collection',
      'anthology',
      'boxset',
      'box set',
    ];
    
    // Check for pack indicators in title or release name
    final hasPackIndicator = packIndicators.any((indicator) => 
      titleLower.contains(indicator) || releaseLower.contains(indicator)
    );
    
    if (hasPackIndicator) return true;
    
    // Check for season-only pattern (S01 without E01)
    // Pattern: has S## but no E## in the release name
    final seasonOnlyPattern = RegExp(r'\bs\d{1,2}\b(?!.*\be\d{1,2}\b)', caseSensitive: false);
    final hasSeasonOnly = seasonOnlyPattern.hasMatch(releaseLower);
    
    // But verify the filename HAS an episode number (confirming it's a pack with selected file)
    final episodeInFilename = RegExp(r'[sS]\d{1,2}[eE]\d{1,2}|[\.\-_]\d{1,2}x\d{1,2}[\.\-_]')
        .hasMatch(filenameLower);
    
    // If release name has season-only but filename has episode = season pack
    if (hasSeasonOnly && episodeInFilename) return true;
    
    // Additional heuristic: if title mentions a specific episode but fileIdx is set,
    // it's likely a single episode with subtitles, NOT a pack
    final hasSpecificEpisode = RegExp(r'[sS]\d{1,2}[eE]\d{1,2}').hasMatch(releaseLower);
    if (hasSpecificEpisode) {
      // Release name has specific episode = probably just video + subs
      return false;
    }
    
    // Default: if we can't determine, treat fileIdx as potential pack
    // but don't heavily penalize
    return false;
  }
  
  /// Get a streaming priority score (higher = better for streaming)
  /// 
  /// This scoring system prioritizes:
  /// 1. Single-file torrents and single-episode releases (no pack download)
  /// 2. Higher quality
  /// 3. More seeders (faster download)
  /// 
  /// A release with video + subtitles is treated the same as a pure single file,
  /// since we only need to download that specific content.
  /// 
  /// Based on how Stremio handles stream selection.
  int get streamingScore {
    int score = 0;
    
    // Strongly prefer single-file OR single-episode releases for streaming
    // Both true single files and single episodes with subs get the bonus
    if (isSingleFile || isSingleEpisodeRelease) {
      score += 1000;
    } else if (isSeasonPack) {
      // True season packs get a penalty (but fileIdx makes them still usable)
      score -= 200;
    }
    
    // Quality bonus
    score += qualityPriority * 100;
    
    // Seeders bonus (capped to prevent dominating)
    score += (seeders.clamp(0, 500));
    
    // Size penalty for very large files (streaming efficiency)
    // Prefer smaller files when quality is similar
    if (sizeBytes > 0) {
      // Penalty for files over 4GB
      if (sizeBytes > 4 * 1024 * 1024 * 1024) {
        score -= 50;
      }
    }
    
    return score;
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'title': title,
      'infoHash': infoHash,
      'fileIdx': fileIdx,
      'behaviorHints': {
        'bingeGroup': bingeGroup,
        'filename': filename,
      },
      'sources': sources,
    };
  }

  /// Extract quality from name (e.g., "Torrentio\n4k" -> "4K")
  String get quality {
    final nameLower = name.toLowerCase();
    if (nameLower.contains('4k') || nameLower.contains('2160p')) return '4K';
    if (nameLower.contains('1080p')) return '1080p';
    if (nameLower.contains('720p')) return '720p';
    if (nameLower.contains('480p')) return '480p';
    if (nameLower.contains('3d')) return '3D';
    if (nameLower.contains('hdrip')) return 'HDRip';
    if (nameLower.contains('dvdrip')) return 'DVDRip';
    if (nameLower.contains('hdtv')) return 'HDTV';
    if (nameLower.contains('bluray') || nameLower.contains('bdrip')) return 'BluRay';
    return 'Unknown';
  }

  /// Get quality priority for sorting (higher is better)
  int get qualityPriority {
    switch (quality) {
      case '4K':
        return 5;
      case '1080p':
        return 4;
      case '720p':
        return 3;
      case 'BluRay':
        return 3;
      case 'WEB-DL':
        return 2;
      case 'HDRip':
        return 2;
      case 'HDTV':
        return 1;
      default:
        return 0;
    }
  }

  /// Extract seeders count from title (e.g., "👤 212" -> 212)
  int get seeders {
    final match = RegExp(r'👤\s*(\d+)').firstMatch(title);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '0') ?? 0;
    }
    return 0;
  }

  /// Extract size from title (e.g., "💾 1.45 GB" -> "1.45 GB")
  String get sizeFormatted {
    final match = RegExp(r'💾\s*([\d.]+\s*[KMGT]?B)').firstMatch(title);
    return match?.group(1) ?? 'Unknown';
  }

  /// Parse size to bytes
  int get sizeBytes {
    final match = RegExp(r'💾\s*([\d.]+)\s*([KMGT]?B)').firstMatch(title);
    if (match == null) return 0;

    final value = double.tryParse(match.group(1) ?? '0') ?? 0;
    final unit = match.group(2) ?? 'B';

    switch (unit.toUpperCase()) {
      case 'TB':
        return (value * 1024 * 1024 * 1024 * 1024).round();
      case 'GB':
        return (value * 1024 * 1024 * 1024).round();
      case 'MB':
        return (value * 1024 * 1024).round();
      case 'KB':
        return (value * 1024).round();
      default:
        return value.round();
    }
  }

  /// Extract source site from title (e.g., "⚙️ ThePirateBay")
  String get sourceSite {
    final match = RegExp(r'⚙️\s*(\w+)').firstMatch(title);
    return match?.group(1) ?? 'Unknown';
  }

  /// Get release name (first line of title)
  String get releaseName {
    return title.split('\n').first;
  }

  /// Generate magnet URI with trackers
  String get magnetUri {
    final trackers = sources
        .where((s) => s.startsWith('tracker:'))
        .map((s) => s.replaceFirst('tracker:', ''))
        .map((t) => '&tr=${Uri.encodeComponent(t)}')
        .join();
    
    final dn = filename != null 
        ? '&dn=${Uri.encodeComponent(filename!)}' 
        : '';
    
    return 'magnet:?xt=urn:btih:$infoHash$dn$trackers';
  }

  /// Health score based on seeds (0-100)
  int get healthScore {
    final s = seeders;
    if (s >= 100) return 100;
    if (s >= 50) return 80;
    if (s >= 20) return 60;
    if (s >= 10) return 40;
    if (s >= 5) return 20;
    if (s > 0) return 10;
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentioStream && infoHash == other.infoHash;

  @override
  int get hashCode => infoHash.hashCode;

  @override
  String toString() =>
      'TorrentioStream(quality: $quality, seeders: $seeders, source: $sourceSite)';
}

/// Response wrapper for Torrentio API
class TorrentioResponse {
  final List<TorrentioStream> streams;
  final int cacheMaxAge;
  final int staleRevalidate;
  final int staleError;

  TorrentioResponse({
    required this.streams,
    this.cacheMaxAge = 3600,
    this.staleRevalidate = 14400,
    this.staleError = 604800,
  });

  factory TorrentioResponse.fromJson(Map<String, dynamic> json) {
    return TorrentioResponse(
      streams: (json['streams'] as List<dynamic>?)
              ?.map((s) => TorrentioStream.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      cacheMaxAge: json['cacheMaxAge'] as int? ?? 3600,
      staleRevalidate: json['staleRevalidate'] as int? ?? 14400,
      staleError: json['staleError'] as int? ?? 604800,
    );
  }
}
