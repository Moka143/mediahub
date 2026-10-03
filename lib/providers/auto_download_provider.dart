import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auto_download_state.dart';
import '../models/episode_grab_result.dart';
import '../services/app_logger.dart';
import '../services/auto_download_service.dart';
import '../services/json_prefs_store.dart';
import '../utils/poll_loop.dart';
import 'auto_download/auto_download_ledger.dart';
import 'auto_download/engine_reconciler.dart';
import 'auto_download/episode_fetcher.dart';
import 'auto_download/episode_grabber.dart';
import 'auto_download_events_provider.dart';
import 'connection_provider.dart';
import 'eztv_provider.dart';
import 'local_media_provider.dart';
import 'settings_provider.dart';
import 'shows_provider.dart';
import 'torrentio_provider.dart';

// Moved out of this file; still importable from here, as before.
export '../models/auto_download_state.dart' show AutoDownloadState;
export '../models/episode_grab_result.dart'
    show EpisodeGrabOutcome, EpisodeGrabResult;

const _autoDownloadStateKey = 'auto_download_state';

/// Provider for AutoDownloadService
final autoDownloadServiceProvider = Provider<AutoDownloadService>((ref) {
  return AutoDownloadService(
    tmdbService: ref.watch(tmdbApiServiceProvider),
    eztvService: ref.watch(eztvApiServiceProvider),
    engine: ref.watch(torrentEngineProvider),
    torrentioService: ref.watch(torrentioApiServiceProvider),
  );
});

/// Provider for auto-download state
final autoDownloadProvider =
    NotifierProvider<AutoDownloadNotifier, AutoDownloadState>(
      AutoDownloadNotifier.new,
    );

/// Auto-download tracking for one show (by TMDB id): the episode it last
/// dealt with and where that stands, or null for a show it has never
/// fetched for. For status indicators on Favorites and Calendar.
final showAutoDownloadTrackingProvider =
    Provider.family<EpisodeTrackingInfo?, int>((ref, showId) {
      return ref.watch(
        autoDownloadProvider.select((s) => s.lastDownloadedEpisodes[showId]),
      );
    });

/// Notifier for auto-download functionality
///
/// Owns the state, saving it, and deciding when to fetch: the settings and
/// per-show gates, the background check and the per-show lock. Whether an
/// episode can be fetched yet is [EpisodeFetcher]'s call, fetching it is
/// [EpisodeGrabber]'s, and keeping the record in step with the engine is
/// [EngineReconciler]'s; they all write through [AutoDownloadLedger].
class AutoDownloadNotifier extends Notifier<AutoDownloadState> {
  /// How often the background check runs.
  static const Duration checkInterval = Duration(minutes: 5);

  late final PollLoop _periodicCheck = PollLoop(
    name: 'auto-download',
    onTick: checkAndDownloadNextEpisodes,
  );

  late JsonPrefsStore _store;

  /// Every write to the queue, the tracking and the activity log; each one
  /// is saved before it returns.
  late final AutoDownloadLedger _ledger = AutoDownloadLedger(
    read: () => state,
    write: (next) => state = next,
    save: _saveState,
    mounted: () => ref.mounted,
    addEvent: (event) =>
        ref.read(autoDownloadEventsProvider.notifier).addEvent(event),
  );

  late final EngineReconciler _reconciler = EngineReconciler(
    ledger: _ledger,
    markCompleted: markDownloadCompleted,
  );

  late final EpisodeFetcher _fetcher = EpisodeFetcher(
    ledger: _ledger,
    quietUntil: _quietUntil,
    grab: _grab,
    qualityFor: getQualityPreference,
  );

  /// One operation per show at a time — see [_withShowLock].
  final Map<int, Completer<void>> _showLocks = {};

  /// Shows the background check should not ask TMDB about again before the
  /// given time: one waiting for an episode to air, a finished series, or
  /// no source found yet. In memory only — a restart checks once and backs
  /// off again.
  final Map<int, DateTime> _quietUntil = {};

  bool _periodicRunning = false;

  @override
  AutoDownloadState build() {
    _store = JsonPrefsStore(
      ref.watch(sharedPreferencesProvider),
      _autoDownloadStateKey,
    );

    // `stop()`, not `dispose()`: Riverpod runs onDispose before every
    // rebuild of this same notifier instance, and a disposed PollLoop never
    // starts again — the background check died on the first rebuild.
    ref.onDispose(_periodicCheck.stop);

    final loadedState = _loadState();
    if (_wantsPeriodicCheck(loadedState)) _startPeriodicCheck();
    return loadedState;
  }

  AutoDownloadState _loadState() {
    final json = _store.readMap();
    if (json == null) return const AutoDownloadState();
    final dropped = <String>{};
    final loaded = AutoDownloadState.fromJson(json, onDropped: dropped.add);
    if (dropped.isNotEmpty) {
      _store.quarantine('unreadable ${dropped.join(', ')}');
    }
    return loaded;
  }

  Future<void> _saveState() async {
    try {
      await _store.write(state.toJson());
    } catch (e) {
      AppLog.e('[AutoDownload] Error saving auto-download state: $e');
    }
  }

  /// Enable or disable auto-download
  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _saveState();
    if (!ref.mounted) return;
    _syncPeriodicCheck();
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

  /// Key for [AutoDownloadState.downloadQueue].
  ///
  /// One producer so every writer and reader agrees byte for byte. They did
  /// not: `onWatchProgress` guarded on a guessed `episode + 1` while the
  /// download path registered whatever TMDB actually resolved, so at a
  /// season boundary the guard checked `S01E11` against a stored `S02E01`
  /// and never matched. The producer is [downloadQueueKey], which the
  /// grab and reconcile steps call; this is its name for tests.
  @visibleForTesting
  static String queueKeyFor(int showId, int season, int episode) =>
      downloadQueueKey(showId, season, episode);

  /// Get quality preference for a show (falls back to default)
  String getQualityPreference(int showId) {
    return state.showQualityPreferences[showId] ?? state.defaultQuality;
  }

  /// Override the auto-download enabled flag for a single show.
  ///
  /// Pass `null` to clear the override and revert to the global setting.
  /// `true` forces auto-download on for this show, `false` forces it off.
  /// Note: this controls only the `enabled` axis — `downloadOnProgress`
  /// and `progressThreshold` remain global.
  Future<void> setShowAutoDownloadOverride(int showId, bool? override) async {
    final overrides = Map<int, bool>.from(state.showAutoDownloadOverrides);
    if (override == null) {
      overrides.remove(showId);
    } else {
      overrides[showId] = override;
    }
    state = state.copyWith(showAutoDownloadOverrides: overrides);
    await _saveState();
    if (!ref.mounted) return;
    _syncPeriodicCheck();
  }

  /// Whether auto-download should fire for [showId]. Resolves the per-show
  /// override against the global flags. For null show ids (movies / untagged
  /// content) falls back to the global gate alone.
  bool isAutoDownloadActiveForShow(int? showId) {
    if (!state.downloadOnProgress) return false;
    if (showId == null) return state.enabled;
    final override = state.showAutoDownloadOverrides[showId];
    return override ?? state.enabled;
  }

  /// Whether the background check covers [showId]: the per-show override, or
  /// else the global switch.
  bool _periodicCoversShow(int showId) =>
      state.showAutoDownloadOverrides[showId] ?? state.enabled;

  bool _wantsPeriodicCheck(AutoDownloadState s) =>
      s.enabled || s.showAutoDownloadOverrides.containsValue(true);

  void _startPeriodicCheck() => _periodicCheck.start(checkInterval);

  void _syncPeriodicCheck() {
    if (_wantsPeriodicCheck(state)) {
      if (!_periodicCheck.isRunning) _startPeriodicCheck();
    } else {
      _periodicCheck.stop();
    }
  }

  /// Run [body] for [showId] once nothing else is running for that show.
  ///
  /// The progress trigger, the background check and a manual grab can all
  /// reach the same episode; between deciding "not queued" and recording the
  /// queue key each awaited network calls, so two of them could both queue
  /// it. Per show, so one slow lookup does not hold up every other show.
  Future<T> _withShowLock<T>(int showId, Future<T> Function() body) async {
    final previous = _showLocks[showId];
    final done = Completer<void>();
    _showLocks[showId] = done;
    try {
      if (previous != null) await previous.future;
      return await body();
    } finally {
      done.complete();
      if (identical(_showLocks[showId], done)) _showLocks.remove(showId);
    }
  }

  /// Trigger auto-download check when watching progress reaches threshold.
  ///
  /// Honours the per-show "Continue Watching" override — i.e. a show with
  /// `showAutoDownloadOverrides[showId] == true` will fire even when the
  /// global `enabled` flag is off. `downloadOnProgress` and the threshold
  /// remain global gates.
  Future<void> onWatchProgress({
    required int showId,
    required String? imdbId,
    required String showName,
    required int season,
    required int episode,
    required double progress,
    required String currentQuality,
  }) async {
    if (!isAutoDownloadActiveForShow(showId)) {
      AppLog.d(
        '[AutoDownload] onWatchProgress skipped: gate closed for showId=$showId',
      );
      return;
    }
    if (progress < state.progressThreshold) {
      AppLog.d(
        '[AutoDownload] onWatchProgress skipped: progress=$progress < '
        'threshold=${state.progressThreshold}',
      );
      return;
    }

    await _withShowLock(showId, () async {
      // This episode is watched. Record it as the show's frontier unless the
      // tracking is already past it, so the background check knows the next
      // one is wanted even if fetching it now fails.
      final tracking = state.lastDownloadedEpisodes[showId];
      if (movesTracking(tracking, season, episode)) {
        await _ledger.updateTracking(
          showId,
          EpisodeTrackingInfo(
            showId: showId,
            imdbId: imdbId ?? tracking?.imdbId,
            showName: showName,
            season: season,
            episode: episode,
            status: EpisodeDownloadStatus.watched,
            quality: currentQuality,
          ),
        );
      }
      if (!ref.mounted) return;

      // Update show quality preference from current episode
      await setShowQualityPreference(showId, currentQuality);
      if (!ref.mounted) return;

      if (imdbId == null) {
        AppLog.w(
          '[AutoDownload] $showName: no IMDB id, nothing to search with',
        );
        return;
      }
      await _fetcher.fetchNextAfter(
        ref.read(autoDownloadServiceProvider),
        showId: showId,
        imdbId: imdbId,
        showName: showName,
        season: season,
        episode: episode,
        quality: currentQuality,
        announce: true,
      );
    });
  }

  /// Check and download next episodes for all tracked shows.
  ///
  /// Only two kinds of show are acted on:
  ///  * **watched** — the tracked episode has been watched, so the next one
  ///    is wanted (and fetching it when it was watched did not work yet);
  ///  * **awaitingTorrent** — the tracked episode itself is wanted and has
  ///    no download: none was found, or the one started left Transfers.
  ///
  /// Everything else is left alone. The comment here always said so, but
  /// the code only skipped `downloading`, so a `downloaded` episode counted
  /// as "go fetch the next one" — every five minutes the next episode came
  /// down as soon as the last finished, until the whole aired backlog had.
  Future<void> checkAndDownloadNextEpisodes() async {
    if (!_wantsPeriodicCheck(state)) return;
    if (_periodicRunning) return;
    _periodicRunning = true;
    state = state.copyWith(isProcessing: true);
    String? failure;

    try {
      await _reconcileWithEngine();
      if (!ref.mounted) return;
      final now = DateTime.now();
      for (final entry in state.lastDownloadedEpisodes.entries.toList()) {
        if (!ref.mounted) return;
        final showId = entry.key;
        final tracking = entry.value;
        if (!_periodicCoversShow(showId) || tracking.imdbId == null) continue;
        final quiet = _quietUntil[showId];
        if (quiet != null && now.isBefore(quiet)) continue;

        switch (tracking.status) {
          case EpisodeDownloadStatus.watched:
            await _withShowLock(
              showId,
              () => _fetcher.fetchNextAfter(
                ref.read(autoDownloadServiceProvider),
                showId: showId,
                imdbId: tracking.imdbId!,
                showName: tracking.showName,
                season: tracking.season,
                episode: tracking.episode,
                quality: getQualityPreference(showId),
                // Every five minutes, every show: a finished series saying
                // so on each pass would flush the 50-entry log within the
                // hour.
                announce: false,
              ),
            );
          case EpisodeDownloadStatus.awaitingTorrent:
            await _withShowLock(
              showId,
              () => _grab(
                EpisodeGrabRequest(
                  showId: showId,
                  imdbId: tracking.imdbId!,
                  showName: tracking.showName,
                  season: tracking.season,
                  episode: tracking.episode,
                  quality: getQualityPreference(showId),
                  excludeHashes: {?tracking.torrentHash},
                  announce: false,
                ),
              ),
            );
          case EpisodeDownloadStatus.notAired ||
              EpisodeDownloadStatus.available ||
              EpisodeDownloadStatus.downloading ||
              EpisodeDownloadStatus.downloaded:
            break;
        }
      }
    } catch (e) {
      failure = e.toString();
      AppLog.e('[AutoDownload] periodic check failed: $e');
    } finally {
      _periodicRunning = false;
      // `error` is clear-on-copy, so it has to be carried through this last
      // copy explicitly — otherwise the `finally` wipes the `catch` above it
      // and the periodic check can fail forever with nothing to show for it.
      if (ref.mounted) {
        state = state.copyWith(isProcessing: false, error: failure);
      }
    }
  }

  /// Fetch [request]'s episode now: check what is already here, find a
  /// source, add it, and record it — see [EpisodeGrabber]. Run under the
  /// show's lock.
  Future<EpisodeGrabResult> _grab(EpisodeGrabRequest request) async {
    final grabber = EpisodeGrabber(
      service: ref.read(autoDownloadServiceProvider),
      ledger: _ledger,
      savePath: ref.read(settingsProvider).defaultSavePath,
      library: () => ref.read(localMediaFilesProvider).value ?? const [],
      quietUntil: _quietUntil,
    );
    return grabber.grab(request);
  }

  /// Fetch [season]x[episode] of a show right now — the Calendar's button.
  ///
  /// The same path as auto-download, so it shares the queue, the tracking
  /// and the duplicate checks: clicking twice does not add the torrent
  /// twice, and an episode that is already here says so. Resolves the IMDB
  /// id itself (from TMDB's external ids) when [imdbId] is null — a [Show]
  /// from TMDB's plain details has none. An episode that has not aired is
  /// not searched for.
  Future<EpisodeGrabResult> downloadEpisodeNow({
    required int showId,
    required String showName,
    String? imdbId,
    required int season,
    required int episode,
  }) {
    return _withShowLock(
      showId,
      () => _fetcher.fetchNow(
        ref.read(autoDownloadServiceProvider),
        showId: showId,
        showName: showName,
        imdbId: imdbId,
        season: season,
        episode: episode,
      ),
    );
  }

  /// Release queue keys and tracking for downloads that have left the
  /// engine, and mark finished ones done — see [EngineReconciler].
  Future<void> _reconcileWithEngine() async {
    final service = ref.read(autoDownloadServiceProvider);
    final torrents = await service.engineTorrents();
    if (torrents == null || !ref.mounted) return; // engine down: no verdict
    await _reconciler.reconcile(torrents);
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

    await _ledger.updateTracking(showId, tracking);
    if (!ref.mounted) return;
    await setShowQualityPreference(showId, quality);
  }

  /// Mark a tracked download as completed when its torrent finishes.
  ///
  /// Releases every queue key recorded for the torrent — see
  /// [EngineReconciler.completeDownload].
  Future<void> markDownloadCompleted(String torrentHash) async {
    await _reconciler.completeDownload(torrentHash);
  }
}
