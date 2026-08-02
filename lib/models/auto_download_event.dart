import '../utils/formatters.dart';

/// Types of auto-download events for the activity log
enum AutoDownloadEventType {
  downloadStarted,
  downloadCompleted,
  downloadFailed,
  torrentNotFound,
  episodeQueued,
  checked,
}

/// A single auto-download activity event
class AutoDownloadEvent {
  final DateTime timestamp;
  final AutoDownloadEventType type;
  final int showId;
  final String showName;
  final int season;
  final int episode;
  final String? quality;
  final String? message;

  AutoDownloadEvent({
    required this.timestamp,
    required this.type,
    required this.showId,
    required this.showName,
    required this.season,
    required this.episode,
    this.quality,
    this.message,
  });

  String get episodeCode => Formatters.episodeCode(season, episode);

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'type': type.index,
    'show_id': showId,
    'show_name': showName,
    'season': season,
    'episode': episode,
    'quality': quality,
    'message': message,
  };

  factory AutoDownloadEvent.fromJson(Map<String, dynamic> json) {
    return AutoDownloadEvent(
      timestamp: DateTime.parse(json['timestamp'] as String),
      type: AutoDownloadEventType.values[json['type'] as int? ?? 0],
      showId: json['show_id'] as int,
      showName: json['show_name'] as String,
      season: json['season'] as int,
      episode: json['episode'] as int,
      quality: json['quality'] as String?,
      message: json['message'] as String?,
    );
  }
}
