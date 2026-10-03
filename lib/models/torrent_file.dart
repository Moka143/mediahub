import '../utils/platform_utils.dart';

/// Represents a file within a torrent
class TorrentFile {
  final int index;
  final String name;
  final int size;
  final double progress;
  final int priority;
  final bool isSeed;
  final List<int>? pieceRange;
  final int availability;

  TorrentFile({
    required this.index,
    required this.name,
    required this.size,
    required this.progress,
    required this.priority,
    required this.isSeed,
    this.pieceRange,
    required this.availability,
  });

  factory TorrentFile.fromJson(Map<String, dynamic> json, int index) {
    return TorrentFile(
      index: index,
      name: json['name'] as String? ?? 'Unknown',
      size: json['size'] as int? ?? 0,
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      priority: json['priority'] as int? ?? 1,
      isSeed: json['is_seed'] as bool? ?? false,
      pieceRange: json['piece_range'] != null
          ? List<int>.from(json['piece_range'] as List)
          : null,
      availability: (json['availability'] as num?)?.toInt() ?? 0,
    );
  }

  /// Progress at or above which a file is treated as finished *for
  /// prioritisation*: not worth deselecting, not worth fetching again.
  ///
  /// Deliberately looser than [isComplete]. Re-prioritising a file that is a
  /// rounding error away from done can kick qBittorrent into a recheck, and
  /// gains nothing.
  static const double nearlyCompleteFraction = 0.999;

  /// Whether every byte of the file is on disk.
  ///
  /// The only test fit for *reading the file directly*. 99.9% of a 4 GB
  /// episode is still four megabytes short, and those are usually the last
  /// ones — the MKV seek index, which is exactly what a player reads first.
  bool get isComplete => progress >= 1.0;

  /// See [nearlyCompleteFraction].
  bool get isNearlyComplete => progress >= nearlyCompleteFraction;

  /// Get the file name without path
  /// qBittorrent reports these with the host's separator, so a Windows
  /// server yields `Season 01\\Episode.mkv`. Splitting on '/' alone left the
  /// whole relative path as the "file name".
  String get fileName => basenameOf(name);

  /// Get the file extension
  String get extension {
    final dotIndex = fileName.lastIndexOf('.');
    return dotIndex != -1 ? fileName.substring(dotIndex + 1).toLowerCase() : '';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TorrentFile &&
          runtimeType == other.runtimeType &&
          index == other.index &&
          name == other.name;

  @override
  int get hashCode => Object.hash(index, name);
}
