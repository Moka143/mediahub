import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../utils/platform_utils.dart';

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

  /// The watched state here has not reached TMDB yet — the rating write (or
  /// its removal) failed, or there was no network to send it on.
  ///
  /// Until it does, this device's mark is the newer truth, and the TMDB
  /// reconcile must not "follow" a remote state that simply has not heard
  /// about it yet: an episode marked watched offline used to be un-marked at
  /// the next launch because TMDB had no rating for it.
  final bool tmdbPushPending;

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
    this.tmdbPushPending = false,
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

  /// Get progress as a value between 0.0 and 1.0
  double get progress {
    if (duration.inMilliseconds == 0) return 0.0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

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

  /// How far in a title counts as finished: the credits.
  static const double completedFraction = 0.90;

  /// Check if should mark as completed ([completedFraction] watched)
  bool get shouldMarkCompleted => progress >= completedFraction;

  /// Finished this title — the persisted flag **or** playback reached
  /// the credits threshold. Library / season-browser watched marks use
  /// this so a 95% watch still counts when `isCompleted` never flipped.
  bool get isEffectivelyWatched => isCompleted || shouldMarkCompleted;

  /// TMDB "not rated" may clear an explicit local mark (synthetics,
  /// "mark watched" on an unopened file). It must not clear a title
  /// we actually played — the rating often never reached TMDB (missing
  /// show id). Zeroing position after a delete used to make a finished
  /// episode look like an explicit mark and get wiped on the next sync.
  ///
  /// Nor a mark TMDB has not been told about yet ([tmdbPushPending]): "not
  /// rated" is then just the old state, not a later decision.
  bool get followsRemoteUnwatch =>
      isCompleted &&
      duration.inMilliseconds == 0 &&
      !shouldMarkCompleted &&
      !tmdbPushPending;

  /// Get display title
  String get displayTitle {
    if (showName != null && episodeCode != null) {
      return '$showName - $episodeCode';
    }
    if (episodeTitle != null) {
      return episodeTitle!;
    }
    // Extract filename from path
    return basenameOf(filePath);
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
      tmdbPushPending: json['tmdb_push_pending'] as bool? ?? false,
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
      // Only when set, so the common row stays the shape older builds wrote.
      if (tmdbPushPending) 'tmdb_push_pending': true,
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
    bool? tmdbPushPending,
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
      tmdbPushPending: tmdbPushPending ?? this.tmdbPushPending,
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
