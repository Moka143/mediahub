import '../services/json_prefs_store.dart';
import '../utils/formatters.dart';

/// Types of auto-download events for the activity log.
///
/// Persisted by index: append new values at the end, never reorder or
/// remove one, or every stored event changes meaning.
enum AutoDownloadEventType {
  downloadStarted,
  downloadCompleted,

  /// A download could not be started, or left Transfers before it finished.
  downloadFailed,

  torrentNotFound,

  /// The next episode has not aired yet; it will be fetched once it has.
  episodeQueued,

  /// Nothing to fetch — the series ended, or the next season is not out.
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
      // Bounds-checked: an index this build does not know (a newer build's
      // event type) drops this one event instead of the whole log.
      type: enumFromJson(
        AutoDownloadEventType.values,
        json['type'],
        AutoDownloadEventType.downloadStarted,
      ),
      showId: json['show_id'] as int,
      showName: json['show_name'] as String,
      season: json['season'] as int,
      episode: json['episode'] as int,
      quality: json['quality'] as String?,
      message: json['message'] as String?,
    );
  }
}
