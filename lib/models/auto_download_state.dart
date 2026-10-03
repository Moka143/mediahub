import '../services/auto_download_service.dart' show EpisodeTrackingInfo;

/// Default quality for new installs and the progress threshold that triggers
/// fetching the next episode — one definition each, used by the state's
/// defaults and by its decoder.
const String _defaultQuality = '1080p';
const double _defaultProgressThreshold = 0.7;

/// State for auto-download feature
class AutoDownloadState {
  /// Whether auto-download is enabled
  final bool enabled;

  /// Default quality preference for auto-downloads
  final String defaultQuality;

  /// Whether to download next episode when current reaches threshold %
  final bool downloadOnProgress;

  /// Progress threshold to trigger download (0.0 - 1.0)
  final double progressThreshold;

  /// Map of show ID -> current quality preference (to match existing downloads)
  final Map<int, String> showQualityPreferences;

  /// Set of episode codes currently queued for download: "showId_S01E01"
  final Set<String> downloadQueue;

  /// The torrent behind each [downloadQueue] key, so a queued download can be
  /// checked against the engine — and its key released when it is gone.
  /// Keys queued by older builds have none.
  final Map<String, String> queuedTorrents;

  /// Map of show ID -> last downloaded episode tracking
  final Map<int, EpisodeTrackingInfo> lastDownloadedEpisodes;

  /// Per-show overrides for the master `enabled` flag — `true` forces auto
  /// download on for that show even when the global toggle is off, `false`
  /// forces it off, missing key = follow global. `downloadOnProgress` and
  /// `progressThreshold` stay global because the threshold model is global.
  /// Surfaced as the in-player "Continue Watching" pill.
  final Map<int, bool> showAutoDownloadOverrides;

  /// Whether auto-download is currently processing
  final bool isProcessing;

  /// Last error message
  final String? error;

  const AutoDownloadState({
    this.enabled = false,
    this.defaultQuality = _defaultQuality,
    this.downloadOnProgress = true,
    this.progressThreshold = _defaultProgressThreshold,
    this.showQualityPreferences = const {},
    this.downloadQueue = const {},
    this.queuedTorrents = const {},
    this.lastDownloadedEpisodes = const {},
    this.showAutoDownloadOverrides = const {},
    this.isProcessing = false,
    this.error,
  });

  /// Deliberately NOT `??`-merged: an error belongs to one update, so every
  /// subsequent copy clears it. Pass it explicitly on any copy that must keep
  /// it — a `finally` that only flips a loading flag will otherwise wipe the
  /// `catch` above it.
  AutoDownloadState copyWith({
    bool? enabled,
    String? defaultQuality,
    bool? downloadOnProgress,
    double? progressThreshold,
    Map<int, String>? showQualityPreferences,
    Set<String>? downloadQueue,
    Map<String, String>? queuedTorrents,
    Map<int, EpisodeTrackingInfo>? lastDownloadedEpisodes,
    Map<int, bool>? showAutoDownloadOverrides,
    bool? isProcessing,
    String? error,
  }) {
    return AutoDownloadState(
      enabled: enabled ?? this.enabled,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      downloadOnProgress: downloadOnProgress ?? this.downloadOnProgress,
      progressThreshold: progressThreshold ?? this.progressThreshold,
      showQualityPreferences:
          showQualityPreferences ?? this.showQualityPreferences,
      downloadQueue: downloadQueue ?? this.downloadQueue,
      queuedTorrents: queuedTorrents ?? this.queuedTorrents,
      lastDownloadedEpisodes:
          lastDownloadedEpisodes ?? this.lastDownloadedEpisodes,
      showAutoDownloadOverrides:
          showAutoDownloadOverrides ?? this.showAutoDownloadOverrides,
      isProcessing: isProcessing ?? this.isProcessing,
      error: error,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'default_quality': defaultQuality,
      'download_on_progress': downloadOnProgress,
      'progress_threshold': progressThreshold,
      'show_quality_preferences': showQualityPreferences.map(
        (k, v) => MapEntry(k.toString(), v),
      ),
      'download_queue': downloadQueue.toList(),
      'queued_torrents': queuedTorrents,
      'last_downloaded_episodes': lastDownloadedEpisodes.map(
        (k, v) => MapEntry(k.toString(), v.toJson()),
      ),
      'show_auto_download_overrides': showAutoDownloadOverrides.map(
        (k, v) => MapEntry(k.toString(), v),
      ),
    };
  }

  /// Decode field by field and entry by entry. One unreadable tracking
  /// entry — an unknown status index, say — used to throw, and the loader
  /// then reset *all* auto-download state, which the next save made final.
  /// [onDropped] hears about every field or entry that was skipped, so the
  /// caller can quarantine the raw value before saving over it.
  factory AutoDownloadState.fromJson(
    Map<String, dynamic> json, {
    void Function(String field)? onDropped,
  }) {
    T field<T>(String key, T fallback, T Function(Object value) read) {
      final raw = json[key];
      if (raw == null) return fallback;
      try {
        return read(raw);
      } catch (_) {
        onDropped?.call(key);
        return fallback;
      }
    }

    Map<K, V> entries<K, V>(
      String key,
      MapEntry<K, V> Function(String key, Object? value) read,
    ) {
      final raw = json[key];
      if (raw == null) return <K, V>{};
      if (raw is! Map) {
        onDropped?.call(key);
        return <K, V>{};
      }
      final out = <K, V>{};
      for (final e in raw.entries) {
        try {
          final decoded = read(e.key as String, e.value);
          out[decoded.key] = decoded.value;
        } catch (_) {
          onDropped?.call(key);
        }
      }
      return out;
    }

    return AutoDownloadState(
      enabled: field('enabled', false, (v) => v as bool),
      defaultQuality: field(
        'default_quality',
        _defaultQuality,
        (v) => v as String,
      ),
      downloadOnProgress: field('download_on_progress', true, (v) => v as bool),
      progressThreshold: field(
        'progress_threshold',
        _defaultProgressThreshold,
        (v) => (v as num).toDouble(),
      ),
      showQualityPreferences: entries(
        'show_quality_preferences',
        (k, v) => MapEntry(int.parse(k), v! as String),
      ),
      downloadQueue: field(
        'download_queue',
        const <String>{},
        (v) => (v as List).whereType<String>().toSet(),
      ),
      queuedTorrents: entries(
        'queued_torrents',
        (k, v) => MapEntry(k, v! as String),
      ),
      lastDownloadedEpisodes: entries(
        'last_downloaded_episodes',
        (k, v) => MapEntry(
          int.parse(k),
          EpisodeTrackingInfo.fromJson(v! as Map<String, dynamic>),
        ),
      ),
      showAutoDownloadOverrides: entries(
        'show_auto_download_overrides',
        (k, v) => MapEntry(int.parse(k), v! as bool),
      ),
    );
  }
}
