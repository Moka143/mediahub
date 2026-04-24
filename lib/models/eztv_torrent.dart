/// Represents a torrent from EZTV API or converted from Torrentio
class EztvTorrent {
  final int id;
  final String hash;
  final String filename;
  final String magnetUrl;
  final String title;
  final int seeds;
  final int peers;
  final int sizeBytes;
  final String? episodeUrl;
  final String? imdbId;
  final int? season;
  final int? episode;
  final String? smallScreenshot;
  final String? largeScreenshot;
  /// File index within a multi-file torrent (from Torrentio)
  /// Used to select specific episode file from season packs
  final int? fileIdx;

  EztvTorrent({
    required this.id,
    required this.hash,
    required this.filename,
    required this.magnetUrl,
    required this.title,
    this.seeds = 0,
    this.peers = 0,
    this.sizeBytes = 0,
    this.episodeUrl,
    this.imdbId,
    this.season,
    this.episode,
    this.smallScreenshot,
    this.largeScreenshot,
    this.fileIdx,
  });

  factory EztvTorrent.fromJson(Map<String, dynamic> json) {
    return EztvTorrent(
      id: json['id'] as int? ?? 0,
      hash: json['hash'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      magnetUrl: json['magnet_url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      seeds: json['seeds'] as int? ?? 0,
      peers: json['peers'] as int? ?? 0,
      sizeBytes: _parseSize(json['size_bytes']),
      episodeUrl: json['episode_url'] as String?,
      imdbId: json['imdb_id'] as String?,
      season: _parseInt(json['season']),
      episode: _parseInt(json['episode']),
      smallScreenshot: json['small_screenshot'] as String?,
      largeScreenshot: json['large_screenshot'] as String?,
    );
  }

  static int _parseSize(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hash': hash,
      'filename': filename,
      'magnet_url': magnetUrl,
      'title': title,
      'seeds': seeds,
      'peers': peers,
      'size_bytes': sizeBytes,
      'episode_url': episodeUrl,
      'imdb_id': imdbId,
      'season': season,
      'episode': episode,
      'small_screenshot': smallScreenshot,
      'large_screenshot': largeScreenshot,
    };
  }

  /// Get formatted file size
  String get sizeFormatted {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    if (sizeBytes < 1024 * 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Extract quality from filename (1080p, 720p, 480p, etc.)
  String get quality {
    final filename_ = filename.toLowerCase();
    if (filename_.contains('2160p') || filename_.contains('4k')) return '4K';
    if (filename_.contains('1080p')) return '1080p';
    if (filename_.contains('720p')) return '720p';
    if (filename_.contains('480p')) return '480p';
    if (filename_.contains('hdtv')) return 'HDTV';
    if (filename_.contains('webrip') || filename_.contains('web-rip')) return 'WEBRip';
    if (filename_.contains('webdl') || filename_.contains('web-dl')) return 'WEB-DL';
    return 'Unknown';
  }

  /// Get episode code (S01E01)
  String? get episodeCode {
    if (season == null || episode == null) return null;
    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');
    return 'S${s}E$e';
  }

  /// Health score based on seeds (0-100)
  int get healthScore {
    if (seeds >= 100) return 100;
    if (seeds >= 50) return 80;
    if (seeds >= 20) return 60;
    if (seeds >= 10) return 40;
    if (seeds >= 5) return 20;
    if (seeds > 0) return 10;
    return 0;
  }

  /// Get quality priority for sorting (higher is better)
  int get qualityPriority {
    switch (quality) {
      case '4K': return 4;
      case '1080p': return 3;
      case '720p': return 2;
      case 'WEB-DL': return 2;
      case 'WEBRip': return 1;
      case 'HDTV': return 1;
      default: return 0;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EztvTorrent && id == other.id && hash == other.hash;

  @override
  int get hashCode => id.hashCode ^ hash.hashCode;

  @override
  String toString() => 'EztvTorrent(id: $id, title: $title, quality: $quality)';
}
