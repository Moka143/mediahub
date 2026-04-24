import '../utils/constants.dart';

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

  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'name': name,
      'size': size,
      'progress': progress,
      'priority': priority,
      'is_seed': isSeed,
      'piece_range': pieceRange,
      'availability': availability,
    };
  }

  /// Get the file name without path
  String get fileName {
    final parts = name.split('/');
    return parts.isNotEmpty ? parts.last : name;
  }

  /// Get the file extension
  String get extension {
    final dotIndex = fileName.lastIndexOf('.');
    return dotIndex != -1 ? fileName.substring(dotIndex + 1).toLowerCase() : '';
  }

  /// Get the priority as enum
  FilePriority get priorityEnum => FilePriority.fromValue(priority);

  /// Check if file will be downloaded
  bool get willDownload => priority > 0;

  /// Check if file is complete
  bool get isComplete => progress >= 1.0;

  TorrentFile copyWith({
    int? index,
    String? name,
    int? size,
    double? progress,
    int? priority,
    bool? isSeed,
    List<int>? pieceRange,
    int? availability,
  }) {
    return TorrentFile(
      index: index ?? this.index,
      name: name ?? this.name,
      size: size ?? this.size,
      progress: progress ?? this.progress,
      priority: priority ?? this.priority,
      isSeed: isSeed ?? this.isSeed,
      pieceRange: pieceRange ?? this.pieceRange,
      availability: availability ?? this.availability,
    );
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
