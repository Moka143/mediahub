import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/peer.dart';
import '../models/torrent.dart';
import '../models/torrent_action_result.dart';
import '../models/torrent_file.dart';
import '../models/tracker.dart';
import '../services/app_logger.dart';
import '../services/torrent_engine.dart';
import '../utils/constants.dart';
import '../utils/debouncer.dart';
import '../utils/poll_loop.dart';
import 'auto_download_provider.dart';
import 'connection_provider.dart';
import 'local_media_provider.dart';
import 'settings_provider.dart';
import 'watch_progress_provider.dart';

/// Turn an error thrown by the torrent engine into a plain sentence for the
/// screen. Never the raw exception text, and never a particular engine's
/// name: the built-in engine's users have no qBittorrent to blame.
@visibleForTesting
String describeEngineError(Object error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return "The torrent engine didn't answer in time";
      case DioExceptionType.connectionError:
        return "Can't reach the torrent engine";
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode;
        return code == null
            ? 'The torrent engine reported an error'
            : 'The torrent engine reported an error (HTTP $code)';
      case DioExceptionType.cancel:
        return 'The request was cancelled';
      case DioExceptionType.badCertificate:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        return 'Something went wrong talking to the torrent engine';
    }
  }
  return 'Something went wrong talking to the torrent engine';
}

/// How long after a torrent finishes, or is deleted, before the library is
/// rescanned — long enough for the engine to finish moving and closing files.
const Duration _libraryRefreshDelay = Duration(seconds: 2);

/// How often an open Torrent Details tab re-reads its files, peers or
/// trackers.
const Duration kTorrentDetailRefreshInterval = Duration(seconds: 3);

/// State for torrent list
class TorrentListState {
  final List<Torrent> torrents;
  final bool isLoading;
  final String? error;

  const TorrentListState({
    this.torrents = const [],
    this.isLoading = false,
    this.error,
  });

  /// Deliberately NOT `??`-merged: an error belongs to one update, so every
  /// subsequent copy clears it. Pass it explicitly on any copy that must keep
  /// it — a `finally` that only flips a loading flag will otherwise wipe the
  /// `catch` above it.
  TorrentListState copyWith({
    List<Torrent>? torrents,
    bool? isLoading,
    String? error,
  }) {
    return TorrentListState(
      torrents: torrents ?? this.torrents,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Provider for torrent list
final torrentListProvider =
    NotifierProvider<TorrentListNotifier, TorrentListState>(
      TorrentListNotifier.new,
    );

/// Provider for torrent search query
class TorrentSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
  void clear() => state = '';
}

final torrentSearchQueryProvider =
    NotifierProvider<TorrentSearchQueryNotifier, String>(
      TorrentSearchQueryNotifier.new,
    );

/// Notifier for torrent list
class TorrentListNotifier extends Notifier<TorrentListState> {
  late final PollLoop _poll = PollLoop(name: 'torrents', onTick: _pollTick);
  final Debouncer _refreshDebouncer = Debouncer(
    delay: const Duration(milliseconds: 500),
  );
  bool _isFirstFetch = true;

  @override
  TorrentListState build() {
    final connectionState = ref.watch(connectionProvider);

    // `stop()`, not `dispose()`. This callback runs on *every* rebuild, not
    // only at teardown — Riverpod runs the previous build's `onDispose`
    // callbacks before re-running `build`, and it reuses this same notifier
    // instance, so `_poll` survives while its disposal flag does not reset.
    // `PollLoop.dispose()` is sticky by design: `_disposed` is never cleared,
    // and `start()` is a permanent no-op afterwards.
    //
    // Because `ConnectionState` published a new identity on every `copyWith`,
    // the very first disconnected -> connecting transition at startup landed
    // here and killed torrent polling for the rest of the session. Nothing
    // looked broken, which is why it went unnoticed: the `Future.microtask`
    // below still fired, its one-shot `refresh` still filled the list, and
    // then progress bars, speeds and the app-bar speed pill simply froze at
    // that first snapshot until something forced a manual refresh.
    //
    // `stop()` cancels the timer and leaves the loop restartable, which is
    // what a rebuild wants. Real teardown runs this too, and a cancelled timer
    // is all that needs.
    ref.onDispose(() {
      _poll.stop();
      _refreshDebouncer.dispose();
    });

    // Start or stop polling based on connection state
    if (connectionState.isConnected) {
      unawaited(Future.microtask(startPolling));
    } else {
      _poll.stop();
      _isFirstFetch = true;
    }

    return const TorrentListState();
  }

  /// Get the current polling interval based on activity
  Duration get _updateInterval {
    final settings = ref.read(settingsProvider);

    // If adaptive polling is disabled, always use the active interval
    if (!settings.useAdaptivePolling) {
      return Duration(seconds: settings.updateIntervalSeconds);
    }

    // Check if there are any active downloads
    final hasActiveDownloads = state.torrents.any((t) => t.isDownloading);

    if (hasActiveDownloads) {
      return Duration(seconds: settings.updateIntervalSeconds);
    } else {
      return Duration(seconds: settings.idlePollingIntervalSeconds);
    }
  }

  /// Start polling for updates.
  ///
  /// The first fetch is a full update; subsequent ticks use the sync delta.
  void startPolling() {
    unawaited(refresh(fullUpdate: _isFirstFetch));
    _poll.start(_updateInterval);
  }

  /// One poll tick: re-evaluate the adaptive cadence, then fetch.
  ///
  /// [PollLoop.setInterval] ignores an unchanged value, so re-deriving it
  /// every tick costs nothing and never resets the schedule out from under
  /// the fetch.
  Future<void> _pollTick() async {
    // The loop is no longer sticky-disposed (see [build]), so the one case it
    // can no longer refuse on its own is a tick already in flight when the
    // provider itself was torn down. Writing `state` then throws; drop the
    // tick instead.
    if (!ref.mounted) return;
    _poll.setInterval(_updateInterval);
    await refresh();
  }

  /// Refresh torrent list using sync endpoint for efficiency
  Future<void> refresh({bool fullUpdate = false}) async {
    if (state.isLoading) return;

    // This build's Ref, not the notifier's current one: if the connection
    // changes mid-fetch the notifier rebuilds against another engine, and
    // this fetch's answer belongs to the old one.
    final buildRef = ref;
    final apiService = ref.read(torrentEngineProvider);
    final previousTorrents = state.torrents;

    try {
      state = state.copyWith(isLoading: true, error: null);

      // Use sync endpoint for efficient delta updates, where there is one.
      // An engine without it (the built-in one has no sync/maindata
      // equivalent) takes the full-fetch branch below, which is why this asks
      // rather than inferring it from a null answer.
      final mainData = apiService.capabilities.deltaSync
          ? await apiService.getMainData(
              fullUpdate: fullUpdate || _isFirstFetch,
            )
          : null;

      if (mainData != null) {
        _isFirstFetch = false;

        // Check if this is a full update or delta
        final isFullUpdate = mainData['full_update'] == true;
        final torrentsData = mainData['torrents'] as Map<String, dynamic>?;
        final removedTorrents = mainData['torrents_removed'] as List<dynamic>?;

        List<Torrent> nextTorrents;
        if (isFullUpdate && torrentsData != null) {
          // Full update - replace all torrents
          nextTorrents = torrentsData.entries
              .map(
                (e) => Torrent.fromJson({
                  ...e.value as Map<String, dynamic>,
                  'hash': e.key,
                }),
              )
              .toList();
        } else {
          // Delta update - merge changes
          final currentTorrents = Map<String, Torrent>.fromEntries(
            state.torrents.map((t) => MapEntry(t.hash, t)),
          );

          // Remove deleted torrents
          if (removedTorrents != null) {
            for (final hash in removedTorrents) {
              currentTorrents.remove(hash as String);
            }
          }

          // Update/add changed torrents
          if (torrentsData != null) {
            for (final entry in torrentsData.entries) {
              final hash = entry.key;
              final data = entry.value as Map<String, dynamic>;

              if (currentTorrents.containsKey(hash)) {
                // Merge with existing torrent data
                final existingTorrent = currentTorrents[hash]!;
                currentTorrents[hash] = existingTorrent.mergeWith(data);
              } else {
                // New torrent
                currentTorrents[hash] = Torrent.fromJson({
                  ...data,
                  'hash': hash,
                });
              }
            }
          }
          nextTorrents = currentTorrents.values.toList();
        }
        if (!buildRef.mounted) return;
        state = TorrentListState(torrents: nextTorrents);
        _reconcileCompletedTorrents(previousTorrents, nextTorrents, apiService);
      } else {
        // No delta endpoint, or it failed: a full fetch.
        final torrents = await apiService.tryGetTorrents();
        if (!buildRef.mounted) return;
        if (torrents == null) {
          // The engine did not answer. Keep showing what we had, with the
          // reason, rather than an empty list that reads as "no torrents".
          state = state.copyWith(
            isLoading: false,
            error: "Can't reach the torrent engine",
          );
          return;
        }
        state = TorrentListState(torrents: torrents);
        _reconcileCompletedTorrents(previousTorrents, torrents, apiService);
      }
    } catch (e) {
      AppLog.w('[Torrents] refresh failed: $e');
      if (!buildRef.mounted) return;
      state = state.copyWith(isLoading: false, error: describeEngineError(e));
    }
  }

  /// Two separate jobs that used to be one, gated on the wrong condition.
  ///
  /// Reporting a finished download to the auto-download tracker was nested
  /// inside the auto-stop-seeding branch, so turning `stopSeedingOnComplete`
  /// off silently disabled it: tracking never left `downloading`, queue
  /// entries never cleared, and the periodic check skipped that show forever.
  /// Completion detection is now unconditional; only the pausing is a setting.
  void _reconcileCompletedTorrents(
    List<Torrent> previous,
    List<Torrent> current,
    TorrentEngine apiService,
  ) {
    final previousByHash = {
      for (final torrent in previous) torrent.hash: torrent,
    };

    // ── 1. Completion edge ────────────────────────────────────────────────
    // Edge-triggered, so the event log doesn't fill with duplicates. On the
    // first snapshot `previous` is empty, which means a download that
    // finished while the app was closed is picked up on the next launch —
    // `markDownloadCompleted` only acts on entries still marked
    // `downloading`, so re-reporting a finished one is a no-op.
    final newlyCompleted = [
      for (final torrent in current)
        if (torrent.isCompleted &&
            !(previousByHash[torrent.hash]?.isCompleted ?? false))
          torrent.hash,
    ];

    if (newlyCompleted.isNotEmpty) {
      final autoDownload = ref.read(autoDownloadProvider.notifier);
      for (final hash in newlyCompleted) {
        unawaited(autoDownload.markDownloadCompleted(hash));
      }
      // Rescan the library once the files have been finalised. Tied to the
      // edge rather than to "any completed torrent is still seeding", which
      // re-scheduled a refresh on every 2 s poll until the engine got round to
      // pausing.
      _rescanLibrarySoon();
    }

    // ── 2. Auto-stop seeding ──────────────────────────────────────────────
    if (!ref.read(settingsProvider).stopSeedingOnComplete) return;

    // Pause every torrent that is currently completed-and-still-seeding.
    // Intentionally idempotent rather than edge-triggered:
    //   1. `apiService.pauseTorrents` is fired with `unawaited`, so a failed
    //      request used to leave the torrent seeding forever (no retry).
    //      Re-checking every poll auto-retries until the engine reports it
    //      paused.
    //   2. Re-streamed / manually-resumed completed torrents transition
    //      pausedUP → uploading, which an edge check would miss because both
    //      states count as `isCompleted`.
    // Once the engine reports the torrent paused (pausedUP/stoppedUP), `isPaused`
    // becomes true and the next poll naturally skips it — so the steady-state
    // cost is zero API calls.
    final toStop = [
      for (final torrent in current)
        if (torrent.isCompleted && !torrent.isPaused) torrent.hash,
    ];
    if (toStop.isEmpty) return;

    unawaited(apiService.pauseTorrents(toStop));
  }

  /// Rescan the library after [_libraryRefreshDelay], the one way every
  /// caller does it ([refreshLocalMediaFromRef]). Invalidating only the file
  /// list, as this used to, re-joined the cached scan and found nothing new.
  void _rescanLibrarySoon({bool cleanUpWatchProgress = false}) {
    unawaited(
      Future<void>.delayed(_libraryRefreshDelay, () {
        if (!ref.mounted) return;
        refreshLocalMediaFromRef(ref);
        if (cleanUpWatchProgress) {
          // Drop watch-progress entries for files that no longer exist.
          unawaited(
            ref.read(watchProgressProvider.notifier).cleanupStaleEntries(),
          );
        }
      }),
    );
  }

  /// Debounced refresh - used after user actions
  void _debouncedRefresh() {
    _refreshDebouncer.run(() => refresh());
  }

  /// Run an engine mutation, turning both failure modes — a thrown exception
  /// and a plain `false` from the API — into a [TorrentActionResult] that
  /// carries a cause the UI can show.
  ///
  /// [onSuccess] runs only when the call succeeded, before the result is
  /// returned, so callers can't forget the follow-up refresh.
  Future<TorrentActionResult> _run(
    String action,
    Future<bool> Function(TorrentEngine api) call, {
    Future<void> Function()? onSuccess,
  }) async {
    final apiService = ref.read(torrentEngineProvider);
    try {
      final ok = await call(apiService);
      if (!ok) {
        AppLog.w('[Torrents] $action rejected by the engine');
        return const TorrentActionResult.failure(
          "The torrent engine didn't accept the request",
        );
      }
      if (onSuccess != null && ref.mounted) await onSuccess();
      return const TorrentActionResult.success();
    } catch (e) {
      AppLog.e('[Torrents] $action failed: $e');
      return TorrentActionResult.failure(describeEngineError(e));
    }
  }

  /// Add torrent from magnet link
  Future<TorrentActionResult> addMagnet(
    String magnetLink, {
    String? savePath,
    bool startNow = true,
  }) {
    return _run(
      'addMagnet',
      (api) => api.addTorrent(
        magnetLink: magnetLink,
        savePath: savePath,
        paused: !startNow,
      ),
      // Immediate refresh for add operations to show the new torrent
      onSuccess: refresh,
    );
  }

  /// Add torrent from file
  Future<TorrentActionResult> addTorrentFile(
    File file, {
    String? savePath,
    bool startNow = true,
  }) {
    return _run(
      'addTorrentFile',
      (api) => api.addTorrent(
        torrentFile: file,
        savePath: savePath,
        paused: !startNow,
      ),
      onSuccess: refresh,
    );
  }

  /// Pause torrent
  Future<TorrentActionResult> pauseTorrent(String hash) =>
      pauseTorrents([hash]);

  /// Pause multiple torrents
  Future<TorrentActionResult> pauseTorrents(List<String> hashes) {
    return _run(
      'pause',
      (api) => api.pauseTorrents(hashes),
      onSuccess: () async => _debouncedRefresh(),
    );
  }

  /// Resume torrent
  Future<TorrentActionResult> resumeTorrent(String hash) =>
      resumeTorrents([hash]);

  /// Resume multiple torrents
  Future<TorrentActionResult> resumeTorrents(List<String> hashes) {
    return _run(
      'resume',
      (api) => api.resumeTorrents(hashes),
      onSuccess: () async => _debouncedRefresh(),
    );
  }

  /// Delete torrent
  Future<TorrentActionResult> deleteTorrent(
    String hash, {
    bool deleteFiles = false,
  }) => deleteTorrents([hash], deleteFiles: deleteFiles);

  /// Delete multiple torrents
  Future<TorrentActionResult> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) {
    return _run(
      'delete',
      (api) => api.deleteTorrents(hashes, deleteFiles: deleteFiles),
      onSuccess: () async {
        // Optimistic local removal so the row disappears in the next frame
        // instead of waiting for the poll cycle to pick up the change.
        final hashSet = hashes.toSet();
        state = state.copyWith(
          torrents: state.torrents
              .where((t) => !hashSet.contains(t.hash))
              .toList(),
        );

        // Clear the master-detail selection if it pointed at a deleted row.
        final selected = ref.read(selectedTorrentHashProvider);
        if (selected != null && hashSet.contains(selected)) {
          ref.read(selectedTorrentHashProvider.notifier).clear();
        }

        // Reconcile with the server — _syncRid was reset on the API side,
        // so this is a full snapshot.
        await refresh(fullUpdate: true);

        _rescanLibrarySoon(cleanUpWatchProgress: true);
      },
    );
  }

  /// Force recheck torrent
  Future<TorrentActionResult> recheckTorrent(String hash) {
    return _run(
      'recheck',
      (api) => api.recheckTorrents([hash]),
      onSuccess: () async => _debouncedRefresh(),
    );
  }

  /// Reannounce torrent to trackers
  Future<TorrentActionResult> reannounceTorrent(String hash) {
    return _run(
      'reannounce',
      (api) => api.reannounceTorrents([hash]),
      onSuccess: () async => _debouncedRefresh(),
    );
  }
}

/// Provider for filtered and sorted torrents
final filteredTorrentsProvider = Provider<List<Torrent>>((ref) {
  final torrentState = ref.watch(torrentListProvider);
  final filter = ref.watch(currentFilterProvider);
  final sort = ref.watch(currentSortProvider);
  final ascending = ref.watch(sortAscendingProvider);
  final query = ref.watch(torrentSearchQueryProvider).trim().toLowerCase();

  var torrents = List<Torrent>.from(torrentState.torrents);

  // Apply filter
  torrents = torrents.where((t) {
    switch (filter) {
      case TorrentFilter.all:
        return true;
      case TorrentFilter.downloading:
        return t.isDownloading;
      case TorrentFilter.seeding:
        return t.isSeeding;
      case TorrentFilter.completed:
        return t.isCompleted;
      case TorrentFilter.paused:
        return t.isPaused;
      case TorrentFilter.active:
        return t.isActive;
      case TorrentFilter.inactive:
        return !t.isActive;
      case TorrentFilter.errored:
        return t.hasError;
    }
  }).toList();

  // Apply search query
  if (query.isNotEmpty) {
    torrents = torrents
        .where((t) => t.name.toLowerCase().contains(query))
        .toList();
  }

  // Apply sort
  torrents.sort((a, b) {
    final int result;
    switch (sort) {
      case TorrentSort.name:
        result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case TorrentSort.size:
        result = a.size.compareTo(b.size);
      case TorrentSort.progress:
        result = a.progress.compareTo(b.progress);
      case TorrentSort.dlspeed:
        result = a.dlspeed.compareTo(b.dlspeed);
      case TorrentSort.upspeed:
        result = a.upspeed.compareTo(b.upspeed);
      case TorrentSort.addedOn:
        result = a.addedOn.compareTo(b.addedOn);
      case TorrentSort.eta:
        result = a.eta.compareTo(b.eta);
    }
    return ascending ? result : -result;
  });

  return torrents;
});

/// Provider for selected torrent hashes (multi-select)
class SelectedTorrentHashesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void toggle(String hash) {
    final next = Set<String>.from(state);
    if (!next.add(hash)) {
      next.remove(hash);
    }
    state = next;
  }

  void addAll(Iterable<String> hashes) {
    state = {...state, ...hashes};
  }

  void clear() => state = <String>{};
}

final selectedTorrentHashesProvider =
    NotifierProvider<SelectedTorrentHashesNotifier, Set<String>>(
      SelectedTorrentHashesNotifier.new,
    );

/// Explicit selection mode state (independent of selected items)
class SelectionModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void enable() => state = true;
  void disable() => state = false;
}

final selectionModeProvider = NotifierProvider<SelectionModeNotifier, bool>(
  SelectionModeNotifier.new,
);

final isSelectionModeProvider = Provider<bool>((ref) {
  final hasSelection = ref.watch(selectedTorrentHashesProvider).isNotEmpty;
  final selectionMode = ref.watch(selectionModeProvider);
  return selectionMode || hasSelection;
});

/// Provider for selected torrent hash
final selectedTorrentHashProvider =
    NotifierProvider<SelectedTorrentHashNotifier, String?>(
      SelectedTorrentHashNotifier.new,
    );

/// Notifier for selected torrent hash
class SelectedTorrentHashNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? value) => state = value;
  void clear() => state = null;
}

/// Re-run the provider holding [ref] every [kTorrentDetailRefreshInterval]
/// for as long as something watches it.
///
/// The detail tabs used to read their data once and keep it forever. These
/// providers are auto-dispose, so the timer — re-armed by each rebuild — dies
/// with the last tab that watches them.
void _refreshWhileWatched(Ref ref) {
  final timer = Timer(kTorrentDetailRefreshInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
}

/// Files of one torrent, refreshed while a tab shows them.
final torrentFilesProvider = FutureProvider.autoDispose
    .family<List<TorrentFile>, String>((ref, hash) async {
      final engine = ref.watch(torrentEngineProvider);
      final connected = ref.watch(
        connectionProvider.select((c) => c.isConnected),
      );
      if (!connected) return const [];
      _refreshWhileWatched(ref);
      return engine.getTorrentFiles(hash);
    });

/// Peers of one torrent, refreshed while a tab shows them.
final torrentPeersProvider = FutureProvider.autoDispose
    .family<List<Peer>, String>((ref, hash) async {
      final engine = ref.watch(torrentEngineProvider);
      final connected = ref.watch(
        connectionProvider.select((c) => c.isConnected),
      );
      if (!connected) return const [];
      _refreshWhileWatched(ref);
      return engine.getTorrentPeers(hash);
    });

/// Trackers of one torrent, refreshed while a tab shows them.
final torrentTrackersProvider = FutureProvider.autoDispose
    .family<List<Tracker>, String>((ref, hash) async {
      final engine = ref.watch(torrentEngineProvider);
      final connected = ref.watch(
        connectionProvider.select((c) => c.isConnected),
      );
      if (!connected) return const [];
      _refreshWhileWatched(ref);
      return engine.getTorrentTrackers(hash);
    });

/// Provider for active downloads count (for navigation badge)
final activeDownloadsCountProvider = Provider<int>((ref) {
  final torrents = ref.watch(torrentListProvider).torrents;
  return torrents.where((t) => t.isDownloading).length;
});

/// Provider for errored torrents count
final erroredTorrentsCountProvider = Provider<int>((ref) {
  final torrents = ref.watch(torrentListProvider).torrents;
  return torrents.where((t) => t.hasError).length;
});
