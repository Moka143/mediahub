import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/auto_download_event.dart';
import '../models/eztv_torrent.dart';
import '../services/auto_download_service.dart';
import 'auto_download_events_provider.dart';
import '../services/eztv_api_service.dart';
import 'connection_provider.dart';
import 'local_media_provider.dart';
import 'settings_provider.dart';
import 'torrentio_provider.dart';

const _autoDownloadStateKey = 'auto_download_state';

/// Provider for AutoDownloadService
final autoDownloadServiceProvider = Provider<AutoDownloadService>((ref) {
  final tmdbService = ref.watch(tmdbServiceProvider);
  final eztvService = ref.watch(eztvApiServiceProvider);
  final qbtService = ref.watch(qbApiServiceProvider);
  final torrentioService = ref.watch(torrentioApiServiceProvider);

  return AutoDownloadService(
    tmdbService: tmdbService,
    eztvService: eztvService,
    qbtService: qbtService,
    torrentioService: torrentioService,
  );
});

/// Provider for EZTV API service
final eztvApiServiceProvider = Provider<EztvApiService>((ref) {
  return EztvApiService();
});

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
  
  /// Map of show ID -> last downloaded episode tracking
  final Map<int, EpisodeTrackingInfo> lastDownloadedEpisodes;
  
  /// Whether auto-download is currently processing
  final bool isProcessing;
  
  /// Last error message
  final String? error;

  const AutoDownloadState({
    this.enabled = false,
    this.defaultQuality = '1080p',
    this.downloadOnProgress = true,
    this.progressThreshold = 0.7,
    this.showQualityPreferences = const {},
    this.downloadQueue = const {},
    this.lastDownloadedEpisodes = const {},
    this.isProcessing = false,
    this.error,
  });

  AutoDownloadState copyWith({
    bool? enabled,
    String? defaultQuality,
    bool? downloadOnProgress,
    double? progressThreshold,
    Map<int, String>? showQualityPreferences,
    Set<String>? downloadQueue,
    Map<int, EpisodeTrackingInfo>? lastDownloadedEpisodes,
    bool? isProcessing,
    String? error,
  }) {
    return AutoDownloadState(
      enabled: enabled ?? this.enabled,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      downloadOnProgress: downloadOnProgress ?? this.downloadOnProgress,
      progressThreshold: progressThreshold ?? this.progressThreshold,
      showQualityPreferences: showQualityPreferences ?? this.showQualityPreferences,
      downloadQueue: downloadQueue ?? this.downloadQueue,
      lastDownloadedEpisodes: lastDownloadedEpisodes ?? this.lastDownloadedEpisodes,
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
      'last_downloaded_episodes': lastDownloadedEpisodes.map(
        (k, v) => MapEntry(k.toString(), v.toJson()),
      ),
    };
  }

  factory AutoDownloadState.fromJson(Map<String, dynamic> json) {
    return AutoDownloadState(
      enabled: json['enabled'] as bool? ?? false,
      defaultQuality: json['default_quality'] as String? ?? '1080p',
      downloadOnProgress: json['download_on_progress'] as bool? ?? true,
      progressThreshold: (json['progress_threshold'] as num?)?.toDouble() ?? 0.7,
      showQualityPreferences: (json['show_quality_preferences'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(int.parse(k), v as String),
          ) ??
          {},
      downloadQueue: (json['download_queue'] as List?)
              ?.map((e) => e as String)
              .toSet() ??
          {},
      lastDownloadedEpisodes:
          (json['last_downloaded_episodes'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(
                  int.parse(k),
                  EpisodeTrackingInfo.fromJson(v as Map<String, dynamic>),
                ),
              ) ??
              {},
    );
  }
}

/// Provider for auto-download state
final autoDownloadProvider = NotifierProvider<AutoDownloadNotifier, AutoDownloadState>(
  AutoDownloadNotifier.new,
);

/// Notifier for auto-download functionality
class AutoDownloadNotifier extends Notifier<AutoDownloadState> {
  Timer? _checkTimer;
  // In-memory lock prevents concurrent periodic + progress-triggered runs
  bool _isRunning = false;

  @override
  AutoDownloadState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    
    ref.onDispose(() {
      _checkTimer?.cancel();
    });

    // Start periodic check if enabled
    final loadedState = _loadState(prefs);
    if (loadedState.enabled) {
      _startPeriodicCheck();
    }

    return loadedState;
  }

  AutoDownloadState _loadState(SharedPreferences prefs) {
    try {
      final jsonString = prefs.getString(_autoDownloadStateKey);
      if (jsonString == null) return const AutoDownloadState();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return AutoDownloadState.fromJson(json);
    } catch (e) {
      print('Error loading auto-download state: $e');
      return const AutoDownloadState();
    }
  }

  Future<void> _saveState() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setString(_autoDownloadStateKey, jsonEncode(state.toJson()));
    } catch (e) {
      print('Error saving auto-download state: $e');
    }
  }

  /// Enable or disable auto-download
  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _saveState();

    if (enabled) {
      _startPeriodicCheck();
    } else {
      _checkTimer?.cancel();
      _checkTimer = null;
    }
  }

  /// Set default quality preference
  Future<void> setDefaultQuality(String quality) async {
    state = state.copyWith(defaultQuality: quality);
    await _saveState();
  }

  /// Set download on progress
  Future<void> setDownloadOnProgress(bool enabled) async {
    state = state.copyWith(downloadOnProgress: enabled);
    await _saveState();
  }

  /// Set progress threshold
  Future<void> setProgressThreshold(double threshold) async {
    state = state.copyWith(progressThreshold: threshold.clamp(0.5, 0.95));
    await _saveState();
  }

  /// Update quality preference for a specific show
  Future<void> setShowQualityPreference(int showId, String quality) async {
    final prefs = Map<int, String>.from(state.showQualityPreferences);
    prefs[showId] = quality;
    state = state.copyWith(showQualityPreferences: prefs);
    await _saveState();
  }

  /// Get quality preference for a show (falls back to default)
  String getQualityPreference(int showId) {
    return state.showQualityPreferences[showId] ?? state.defaultQuality;
  }

  /// Start periodic check for next episodes
  void _startPeriodicCheck() {
    _checkTimer?.cancel();
    // Check every 5 minutes
    _checkTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      checkAndDownloadNextEpisodes();
    });
  }

  /// Trigger auto-download check when watching progress reaches threshold
  Future<void> onWatchProgress({
    required int showId,
    required String? imdbId,
    required String showName,
    required int season,
    required int episode,
    required double progress,
    required String currentQuality,
  }) async {
    if (!state.enabled || !state.downloadOnProgress) return;
    if (progress < state.progressThreshold) return;

    // Mark the current episode as watched in tracking
    final currentTracking = state.lastDownloadedEpisodes[showId];
    if (currentTracking != null &&
        currentTracking.season == season &&
        currentTracking.episode == episode &&
        currentTracking.status != EpisodeDownloadStatus.watched) {
      await _updateTracking(showId, currentTracking.copyWith(
        status: EpisodeDownloadStatus.watched,
      ));
    }

    // Generate queue key
    final nextEpNum = episode + 1;
    final queueKey = '${showId}_S${season.toString().padLeft(2, '0')}E${nextEpNum.toString().padLeft(2, '0')}';

    // Check if already in queue
    if (state.downloadQueue.contains(queueKey)) return;

    // Update show quality preference from current episode
    await setShowQualityPreference(showId, currentQuality);

    // Trigger next episode download
    await _downloadNextEpisode(
      showId: showId,
      imdbId: imdbId,
      showName: showName,
      currentSeason: season,
      currentEpisode: episode,
      quality: currentQuality,
    );
  }

  /// Check and download next episodes for all tracked shows
  Future<void> checkAndDownloadNextEpisodes() async {
    if (!state.enabled) return;
    // Guard against concurrent calls (timer + progress-triggered)
    if (_isRunning || state.isProcessing) return;
    _isRunning = true;

    state = state.copyWith(isProcessing: true);

    try {
      final service = ref.read(autoDownloadServiceProvider);
      final downloadedFiles = ref.read(localMediaFilesProvider).value ?? [];

      // Check each tracked show's last downloaded episode
      for (final entry in state.lastDownloadedEpisodes.entries) {
        final showId = entry.key;
        final tracking = entry.value;

        if (tracking.imdbId == null) continue;

        // Don't chain-download: skip shows where the last tracked episode
        // hasn't been watched yet. Only onWatchProgress() should advance
        // downloads — the periodic check just retries failed/missing ones.
        if (tracking.status == EpisodeDownloadStatus.downloading) continue;

        // Get next episode info
        final nextResult = await service.getNextEpisode(
          showId: showId,
          currentSeason: tracking.season,
          currentEpisode: tracking.episode,
        );

        if (!nextResult.hasNextEpisode) continue;

        final nextEp = nextResult.nextEpisode!;

        // Check if already downloaded
        final isDownloaded = service.isEpisodeDownloaded(
          downloadedFiles: downloadedFiles,
          showName: tracking.showName,
          season: nextEp.seasonNumber,
          episode: nextEp.episodeNumber,
        );

        if (isDownloaded) continue;

        // Check if currently downloading
        final isDownloading = await service.isEpisodeCurrentlyDownloading(
          showName: tracking.showName,
          season: nextEp.seasonNumber,
          episode: nextEp.episodeNumber,
        );

        if (isDownloading) continue;

        // Find and download torrent
        final quality = getQualityPreference(showId);
        final torrent = await service.findTorrentForEpisode(
          imdbId: tracking.imdbId!,
          season: nextEp.seasonNumber,
          episode: nextEp.episodeNumber,
          preferredQuality: quality,
        );

        if (torrent != null) {
          final settings = ref.read(settingsProvider);
          await service.downloadNextEpisode(
            magnetLink: torrent.magnetUrl,
            savePath: settings.defaultSavePath,
            infoHash: torrent.hash,
            fileIdx: torrent.fileIdx,
          );

          // Update tracking
          await _updateTracking(showId, tracking.copyWith(
            season: nextEp.seasonNumber,
            episode: nextEp.episodeNumber,
            status: EpisodeDownloadStatus.downloading,
            torrentHash: torrent.hash,
          ));
        }
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      _isRunning = false;
      state = state.copyWith(isProcessing: false);
    }
  }

  /// Download next episode for a specific show
  Future<bool> _downloadNextEpisode({
    required int showId,
    required String? imdbId,
    required String showName,
    required int currentSeason,
    required int currentEpisode,
    required String quality,
  }) async {
    if (imdbId == null) return false;

    final service = ref.read(autoDownloadServiceProvider);
    final downloadedFiles = ref.read(localMediaFilesProvider).value ?? [];

    // Get next episode
    final nextResult = await service.getNextEpisode(
      showId: showId,
      currentSeason: currentSeason,
      currentEpisode: currentEpisode,
    );

    if (!nextResult.hasNextEpisode) {
      ref.read(autoDownloadEventsProvider.notifier).addEvent(
        AutoDownloadEvent(
          timestamp: DateTime.now(),
          type: AutoDownloadEventType.checked,
          showId: showId,
          showName: showName,
          season: currentSeason,
          episode: currentEpisode,
          message: nextResult.message ?? 'No next episode available',
        ),
      );
      return false;
    }

    final nextEp = nextResult.nextEpisode!;

    // Check if already downloaded
    if (service.isEpisodeDownloaded(
      downloadedFiles: downloadedFiles,
      showName: showName,
      season: nextEp.seasonNumber,
      episode: nextEp.episodeNumber,
    )) {
      return false;
    }

    // Find torrent
    final torrent = await service.findTorrentForEpisode(
      imdbId: imdbId,
      season: nextEp.seasonNumber,
      episode: nextEp.episodeNumber,
      preferredQuality: quality,
    );

    if (torrent == null) {
      ref.read(autoDownloadEventsProvider.notifier).addEvent(
        AutoDownloadEvent(
          timestamp: DateTime.now(),
          type: AutoDownloadEventType.torrentNotFound,
          showId: showId,
          showName: showName,
          season: nextEp.seasonNumber,
          episode: nextEp.episodeNumber,
          quality: quality,
          message: 'No torrent found for $showName ${nextEp.episodeCode}',
        ),
      );
      return false;
    }

    // Download
    final settings = ref.read(settingsProvider);
    final success = await service.downloadNextEpisode(
      magnetLink: torrent.magnetUrl,
      savePath: settings.defaultSavePath,
      infoHash: torrent.hash,
      fileIdx: torrent.fileIdx,
    );

    if (success) {
      // Add to queue and update tracking
      final queueKey = '${showId}_${nextEp.episodeCode}';
      state = state.copyWith(
        downloadQueue: {...state.downloadQueue, queueKey},
      );

      await _updateTracking(showId, EpisodeTrackingInfo(
        showId: showId,
        imdbId: imdbId,
        showName: showName,
        season: nextEp.seasonNumber,
        episode: nextEp.episodeNumber,
        status: EpisodeDownloadStatus.downloading,
        quality: torrent.quality,
        torrentHash: torrent.hash,
        magnetLink: torrent.magnetUrl,
      ));

      ref.read(autoDownloadEventsProvider.notifier).addEvent(
        AutoDownloadEvent(
          timestamp: DateTime.now(),
          type: AutoDownloadEventType.downloadStarted,
          showId: showId,
          showName: showName,
          season: nextEp.seasonNumber,
          episode: nextEp.episodeNumber,
          quality: quality,
          message: 'Started downloading $showName ${nextEp.episodeCode} in $quality',
        ),
      );
    }

    return success;
  }

  /// Update episode tracking
  Future<void> _updateTracking(int showId, EpisodeTrackingInfo tracking) async {
    final newTracking = Map<int, EpisodeTrackingInfo>.from(state.lastDownloadedEpisodes);
    newTracking[showId] = tracking;
    state = state.copyWith(lastDownloadedEpisodes: newTracking);
    await _saveState();
  }

  /// Track a show for auto-download (call when starting to watch)
  Future<void> trackShow({
    required int showId,
    required String? imdbId,
    required String showName,
    required int season,
    required int episode,
    required String quality,
  }) async {
    final tracking = EpisodeTrackingInfo(
      showId: showId,
      imdbId: imdbId,
      showName: showName,
      season: season,
      episode: episode,
      status: EpisodeDownloadStatus.downloaded,
      quality: quality,
    );

    await _updateTracking(showId, tracking);
    await setShowQualityPreference(showId, quality);
  }

  /// Remove a show from tracking
  Future<void> untrackShow(int showId) async {
    final newTracking = Map<int, EpisodeTrackingInfo>.from(state.lastDownloadedEpisodes);
    newTracking.remove(showId);
    state = state.copyWith(lastDownloadedEpisodes: newTracking);
    await _saveState();
  }

  /// Clear download queue entry when download completes
  Future<void> clearQueueEntry(String queueKey) async {
    final newQueue = Set<String>.from(state.downloadQueue)..remove(queueKey);
    state = state.copyWith(downloadQueue: newQueue);
    await _saveState();
  }

  /// Mark a tracked download as completed when its torrent finishes
  Future<void> markDownloadCompleted(String torrentHash) async {
    for (final entry in state.lastDownloadedEpisodes.entries) {
      final tracking = entry.value;
      if (tracking.torrentHash == torrentHash &&
          tracking.status == EpisodeDownloadStatus.downloading) {
        // Update status to downloaded
        await _updateTracking(entry.key, tracking.copyWith(
          status: EpisodeDownloadStatus.downloaded,
        ));

        // Clear the queue entry
        final queueKey = '${entry.key}_${tracking.episodeCode}';
        await clearQueueEntry(queueKey);

        // Log the event
        ref.read(autoDownloadEventsProvider.notifier).addEvent(
          AutoDownloadEvent(
            timestamp: DateTime.now(),
            type: AutoDownloadEventType.downloadCompleted,
            showId: tracking.showId,
            showName: tracking.showName,
            season: tracking.season,
            episode: tracking.episode,
            quality: tracking.quality,
            message: '${tracking.showName} ${tracking.episodeCode} finished downloading',
          ),
        );
        return;
      }
    }
  }
}

/// Provider for next episode info (for a specific show/episode)
final nextEpisodeProvider = FutureProvider.family<NextEpisodeResult, ({int showId, int season, int episode})>(
  (ref, params) async {
    final service = ref.watch(autoDownloadServiceProvider);
    return service.getNextEpisode(
      showId: params.showId,
      currentSeason: params.season,
      currentEpisode: params.episode,
    );
  },
);

/// Provider to check if next episode is downloaded
final isNextEpisodeDownloadedProvider = Provider.family<bool, ({String showName, int season, int episode})>(
  (ref, params) {
    final service = ref.watch(autoDownloadServiceProvider);
    final downloadedFiles = ref.watch(localMediaFilesProvider).value ?? [];
    
    return service.isEpisodeDownloaded(
      downloadedFiles: downloadedFiles,
      showName: params.showName,
      season: params.season,
      episode: params.episode,
    );
  },
);

/// Provider for available torrents for an episode
final episodeTorrentsProvider = FutureProvider.family<List<EztvTorrent>, ({String imdbId, int season, int episode})>(
  (ref, params) async {
    final service = ref.watch(autoDownloadServiceProvider);
    return service.getAvailableTorrentsForEpisode(
      imdbId: params.imdbId,
      season: params.season,
      episode: params.episode,
    );
  },
);
