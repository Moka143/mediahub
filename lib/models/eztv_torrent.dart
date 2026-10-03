import '../utils/media_quality.dart';

/// Represents a torrent from EZTV API or converted from Torrentio
class EztvTorrent {
  final int id;
  final String hash;
  final String filename;
  final String magnetUrl;
  final String title;
  final int seeds;
  final int sizeBytes;
  final int? season;
  final int? episode;

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
    this.sizeBytes = 0,
    this.season,
    this.episode,
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
      sizeBytes: _parseSize(json['size_bytes']),
      season: _parseInt(json['season']),
      episode: _parseInt(json['episode']),
      // EZTV itself never sends this; a converted Torrentio result does, and
      // it is the one field that picks an episode out of a season pack.
      // Dropping it on a round-trip would silently stream the wrong file.
      fileIdx: _parseInt(json['file_idx']),
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

  /// Release quality derived from the filename. See [MediaQuality] — this
  /// used to be a private ladder that checked `hdtv` before `web-dl`, which
  /// classified `HDTV.WEB-DL` differently from `TorrentioStream`.
  MediaQuality get mediaQuality => MediaQuality.fromText(filename);

  /// Canonical quality label, e.g. `1080p`.
  String get quality => mediaQuality.label;

  /// Get quality priority for sorting (higher is better)
  int get qualityPriority => mediaQuality.rank;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EztvTorrent && id == other.id && hash == other.hash;

  @override
  int get hashCode => id.hashCode ^ hash.hashCode;

  @override
  String toString() => 'EztvTorrent(id: $id, title: $title, quality: $quality)';
}
