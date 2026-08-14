import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../utils/formatters.dart';

/// Represents watch progress for a video file
class WatchProgress {
  final String fileHash; // MD5 hash of file path for unique ID
  final String filePath; // Full path to video file
  final String? showName; // Matched show name (nullable)
  final int? showId; // TMDB show ID (nullable)
  final int? seasonNumber; // Season number (nullable)
  final int? episodeNumber; // Episode number (nullable)
  final String? episodeCode; // "S01E05" format
  final String? episodeTitle; // Episode title
  final int? movieId; // TMDB movie ID (nullable; only set for movies)
  final String? posterPath; // Show / movie poster for display
  final Duration position; // Current playback position
  final Duration duration; // Total video duration
  final DateTime lastWatched; // Last watch timestamp
  final bool isCompleted; // True if > 90% watched

  WatchProgress({
    required this.fileHash,
    required this.filePath,
    this.showName,
    this.showId,
    this.seasonNumber,
    this.episodeNumber,
    this.episodeCode,
    this.episodeTitle,
    this.movieId,
    this.posterPath,
    required this.position,
    required this.duration,
    required this.lastWatched,
    this.isCompleted = false,
  });

  /// Generate hash from file path
  static String generateHash(String filePath) {
    return md5.convert(utf8.encode(filePath)).toString();
  }

  /// Path prefixes used for entries that carry a watched mark but do not
  /// refer to a real file on disk.
  ///
  /// `tmdb:rated:` / `tmdb:rated-movie:` are written by the TMDB reconcile
  /// for things watched on another device and never downloaded here;
  /// `manual:watched:` by the legacy manual-watched migration. Both exist
  /// so the watched mark has somewhere to live — they are never playable
  /// and must be excluded from Continue Watching and the library.
  static const syntheticPathPrefixes = [
    'tmdb:rated:',
    'tmdb:rated-movie:',
    'manual:watched:',
  ];

  /// Whether [filePath] is one of the synthetic, non-playable paths above.
  static bool isSyntheticPath(String filePath) =>
      syntheticPathPrefixes.any(filePath.startsWith);

  /// Whether this entry refers to a real file rather than a watched-only
  /// placeholder.
  bool get isRealFile => !isSyntheticPath(filePath);

  /// Get progress as a value between 0.0 and 1.0
  double get progress {
    if (duration.inMilliseconds == 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Get progress as percentage string
  String get progressPercent => '${(progress * 100).toInt()}%';

  /// Get remaining time
  Duration get remaining => duration - position;

  /// Get remaining time formatted
  String get remainingFormatted {
    final mins = remaining.inMinutes;
    if (mins < 60) return '${mins}m left';
    final hours = mins ~/ 60;
    final remainingMins = mins % 60;
    return '${hours}h ${remainingMins}m left';
  }

  /// Get position formatted (HH:MM:SS or MM:SS)
  String get positionFormatted => Formatters.formatPlaybackDuration(position);

  /// Get duration formatted
  String get durationFormatted => Formatters.formatPlaybackDuration(duration);

  /// Check if should mark as completed (> 90% watched)
  bool get shouldMarkCompleted => progress >= 0.90;

  /// Finished this title — the persisted flag **or** playback reached
  /// the credits threshold. Library / season-browser watched marks use
  /// this so a 95% watch still counts when `isCompleted` never flipped.
  bool get isEffectivelyWatched => isCompleted || shouldMarkCompleted;

  /// TMDB "not rated" may clear an explicit local mark (synthetics,
  /// "mark watched" on an unopened file). It must not clear a title
  /// we actually played — the rating often never reached TMDB (missing
  /// show id). Zeroing position after a delete used to make a finished
  /// episode look like an explicit mark and get wiped on the next sync.
  bool get followsRemoteUnwatch =>
      isCompleted && duration.inMilliseconds == 0 && !shouldMarkCompleted;

  /// Get display title
  String get displayTitle {
    if (showName != null && episodeCode != null) {
      return '$showName - $episodeCode';
    }
    if (episodeTitle != null) {
      return episodeTitle!;
    }
    // Extract filename from path
    return filePath.split('/').last.split('\\').last;
  }

  factory WatchProgress.fromJson(Map<String, dynamic> json) {
    return WatchProgress(
      fileHash: json['file_hash'] as String,
      filePath: json['file_path'] as String,
      showName: json['show_name'] as String?,
      showId: json['show_id'] as int?,
      seasonNumber: json['season_number'] as int?,
      episodeNumber: json['episode_number'] as int?,
      episodeCode: json['episode_code'] as String?,
      episodeTitle: json['episode_title'] as String?,
      movieId: json['movie_id'] as int?,
      posterPath: json['poster_path'] as String?,
      position: Duration(milliseconds: json['position_ms'] as int? ?? 0),
      duration: Duration(milliseconds: json['duration_ms'] as int? ?? 0),
      lastWatched:
          DateTime.tryParse(json['last_watched'] as String? ?? '') ??
          DateTime.now(),
      isCompleted: json['is_completed'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'file_hash': fileHash,
      'file_path': filePath,
      'show_name': showName,
      'show_id': showId,
      'season_number': seasonNumber,
      'episode_number': episodeNumber,
      'episode_code': episodeCode,
      'episode_title': episodeTitle,
      'movie_id': movieId,
      'poster_path': posterPath,
      'position_ms': position.inMilliseconds,
      'duration_ms': duration.inMilliseconds,
      'last_watched': lastWatched.toIso8601String(),
      'is_completed': isCompleted,
    };
  }

  WatchProgress copyWith({
    String? fileHash,
    String? filePath,
    String? showName,
    int? showId,
    int? seasonNumber,
    int? episodeNumber,
    String? episodeCode,
    String? episodeTitle,
    int? movieId,
    String? posterPath,
    Duration? position,
    Duration? duration,
    DateTime? lastWatched,
    bool? isCompleted,
  }) {
    return WatchProgress(
      fileHash: fileHash ?? this.fileHash,
      filePath: filePath ?? this.filePath,
      showName: showName ?? this.showName,
      showId: showId ?? this.showId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      episodeCode: episodeCode ?? this.episodeCode,
      episodeTitle: episodeTitle ?? this.episodeTitle,
      movieId: movieId ?? this.movieId,
      posterPath: posterPath ?? this.posterPath,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      lastWatched: lastWatched ?? this.lastWatched,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WatchProgress &&
          runtimeType == other.runtimeType &&
          fileHash == other.fileHash;

  @override
  int get hashCode => fileHash.hashCode;
}
