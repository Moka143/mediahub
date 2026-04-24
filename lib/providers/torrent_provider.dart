import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/peer.dart';
import '../models/torrent.dart';
import '../models/torrent_file.dart';
import '../models/tracker.dart';
import '../services/qbittorrent_api_service.dart';
import '../utils/constants.dart';
import '../utils/debouncer.dart';
import 'auto_download_provider.dart';
import 'connection_provider.dart';
import 'local_media_provider.dart';
import 'settings_provider.dart';
import 'watch_progress_provider.dart';

/// State for torrent list
class TorrentListState {
  final List<Torrent> torrents;
  final bool isLoading;
  final String? error;
  final DateTime? lastUpdated;

  const TorrentListState({
    this.torrents = const [],
    this.isLoading = false,
    this.error,
    this.lastUpdated,
  });

  TorrentListState copyWith({
    List<Torrent>? torrents,
    bool? isLoading,
    String? error,
    DateTime? lastUpdated,
  }) {
    return TorrentListState(
      torrents: torrents ?? this.torrents,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      lastUpdated: lastUpdated ?? this.lastUpdated,
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
  Timer? _pollingTimer;
  Duration? _currentPollingInterval;
  final Debouncer _refreshDebouncer = Debouncer(
    delay: const Duration(milliseconds: 500),
  );
  bool _isFirstFetch = true;

  @override
  TorrentListState build() {
    final connectionState = ref.watch(connectionProvider);

    // Clean up timer and debouncer on dispose
    ref.onDispose(() {
      _pollingTimer?.cancel();
      _refreshDebouncer.dispose();
    });

    // Start or stop polling based on connection state
    if (connectionState.isConnected) {
      Future.microtask(() => startPolling());
    } else {
      _pollingTimer?.cancel();
      _pollingTimer = null;
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

  /// Start polling for updates
  void startPolling() {
    _pollingTimer?.cancel();
    _currentPollingInterval = _updateInterval;
    refresh(fullUpdate: _isFirstFetch); // Full update on first fetch
    _pollingTimer = Timer.periodic(_currentPollingInterval!, (_) {
      _checkAndAdjustPolling();
      refresh();
    });
  }

  /// Check if polling interval should be adjusted based on activity
  void _checkAndAdjustPolling() {
    final newInterval = _updateInterval;
    if (_currentPollingInterval != newInterval) {
      _currentPollingInterval = newInterval;
      // Restart timer with new interval
      _pollingTimer?.cancel();
      _pollingTimer = Timer.periodic(newInterval, (_) {
        _checkAndAdjustPolling();
        refresh();
      });
    }
  }

  /// Stop polling
  void stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  /// Refresh torrent list using sync endpoint for efficiency
  Future<void> refresh({bool fullUpdate = false}) async {
    if (state.isLoading) return;

    final apiService = ref.read(qbApiServiceProvider);
    final previousTorrents = state.torrents;

    try {
      state = state.copyWith(isLoading: true, error: null);

      // Use sync endpoint for efficient delta updates
      final mainData = await apiService.getMainData(
        fullUpdate: fullUpdate || _isFirstFetch,
      );

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
        state = TorrentListState(
          torrents: nextTorrents,
          isLoading: false,
          lastUpdated: DateTime.now(),
        );
        _maybeAutoStopSeeding(previousTorrents, nextTorrents, apiService);
      } else {
        // Fallback to full fetch if sync endpoint fails
        final torrents = await apiService.getTorrents();
        state = TorrentListState(
          torrents: torrents,
          isLoading: false,
          lastUpdated: DateTime.now(),
        );
        _maybeAutoStopSeeding(previousTorrents, torrents, apiService);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void _maybeAutoStopSeeding(
    List<Torrent> previous,
    List<Torrent> current,
    QBittorrentApiService apiService,
  ) {
    final settings = ref.read(settingsProvider);
    if (!settings.stopSeedingOnComplete) return;

    final toStop = <String>[];

    // On first load (no previous state), stop any already completed & seeding torrents
    if (previous.isEmpty) {
      for (final torrent in current) {
        if (torrent.isCompleted && !torrent.isPaused) {
          toStop.add(torrent.hash);
        }
      }
    } else {
      // Normal case: detect newly completed torrents
      final previousByHash = {
        for (final torrent in previous) torrent.hash: torrent,
      };

      for (final torrent in current) {
        final prev = previousByHash[torrent.hash];
        final wasCompleted = prev?.isCompleted ?? false;
        if (!wasCompleted && torrent.isCompleted && !torrent.isPaused) {
          toStop.add(torrent.hash);
        }
      }
    }

    if (toStop.isNotEmpty) {
      unawaited(apiService.pauseTorrents(toStop));
      // Trigger media refresh after a short delay to allow files to be finalized
      Future.delayed(const Duration(seconds: 2), () {
        ref.invalidate(localMediaFilesProvider);
      });

      // Notify auto-download that these torrents completed
      for (final hash in toStop) {
        ref.read(autoDownloadProvider.notifier).markDownloadCompleted(hash);
      }
    }
  }

  /// Debounced refresh - used after user actions
  void _debouncedRefresh() {
    _refreshDebouncer.run(() => refresh());
  }

  /// Add torrent from magnet link
  Future<bool> addMagnet(
    String magnetLink, {
    String? savePath,
    bool startNow = true,
  }) async {
    final apiService = ref.read(qbApiServiceProvider);

    try {
      final success = await apiService.addTorrent(
        magnetLink: magnetLink,
        savePath: savePath,
        paused: !startNow,
      );

      if (success) {
        // Immediate refresh for add operations to show the new torrent
        await refresh();
      }

      return success;
    } catch (e) {
      return false;
    }
  }

  /// Add torrent from file
  Future<bool> addTorrentFile(
    File file, {
    String? savePath,
    bool startNow = true,
  }) async {
    final apiService = ref.read(qbApiServiceProvider);

    try {
      final success = await apiService.addTorrent(
        torrentFile: file,
        savePath: savePath,
        paused: !startNow,
      );

      if (success) {
        // Immediate refresh for add operations to show the new torrent
        await refresh();
      }

      return success;
    } catch (e) {
      return false;
    }
  }

  /// Pause torrent
  Future<bool> pauseTorrent(String hash) async {
    return await pauseTorrents([hash]);
  }

  /// Pause multiple torrents
  Future<bool> pauseTorrents(List<String> hashes) async {
    final apiService = ref.read(qbApiServiceProvider);

    try {
      final success = await apiService.pauseTorrents(hashes);
      if (success) {
        _debouncedRefresh();
      }
      return success;
    } catch (e) {
      return false;
    }
  }

  /// Resume torrent
  Future<bool> resumeTorrent(String hash) async {
    return await resumeTorrents([hash]);
  }

  /// Resume multiple torrents
  Future<bool> resumeTorrents(List<String> hashes) async {
    final apiService = ref.read(qbApiServiceProvider);

    try {
      final success = await apiService.resumeTorrents(hashes);
      if (success) {
        _debouncedRefresh();
      }
      return success;
    } catch (e) {
      return false;
    }
  }

  /// Delete torrent
  Future<bool> deleteTorrent(String hash, {bool deleteFiles = false}) async {
    return await deleteTorrents([hash], deleteFiles: deleteFiles);
  }

  /// Delete multiple torrents
  Future<bool> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async {
    final apiService = ref.read(qbApiServiceProvider);

    try {
      final success = await apiService.deleteTorrents(
        hashes,
        deleteFiles: deleteFiles,
      );
      if (success) {
        // Immediate refresh for delete to update UI right away
        await refresh();
        // Refresh media files after a short delay to allow file system to update
        Future.delayed(const Duration(seconds: 2), () {
          ref.invalidate(localMediaStreamProvider);
          ref.invalidate(localMediaScannerProvider);
          ref.invalidate(localMediaFilesProvider);
          // Clean up watch progress entries for files that no longer exist
          ref.read(watchProgressProvider.notifier).cleanupStaleEntries();
        });
      }
      return success;
    } catch (e) {
      return false;
    }
  }

  /// Force recheck torrent
  Future<bool> recheckTorrent(String hash) async {
    final apiService = ref.read(qbApiServiceProvider);

    try {
      final success = await apiService.recheckTorrents([hash]);
      if (success) {
        _debouncedRefresh();
      }
      return success;
    } catch (e) {
      return false;
    }
  }

  /// Reannounce torrent to trackers
  Future<bool> reannounceTorrent(String hash) async {
    final apiService = ref.read(qbApiServiceProvider);

    try {
      final success = await apiService.reannounceTorrents([hash]);
      if (success) {
        _debouncedRefresh();
      }
      return success;
    } catch (e) {
      return false;
    }
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
  void set(bool value) => state = value;
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

/// Provider for selected torrent
final selectedTorrentProvider = Provider<Torrent?>((ref) {
  final hash = ref.watch(selectedTorrentHashProvider);
  if (hash == null) return null;

  final torrents = ref.watch(torrentListProvider).torrents;
  return torrents.where((t) => t.hash == hash).firstOrNull;
});

/// Provider for torrent files
final torrentFilesProvider = FutureProvider.family<List<TorrentFile>, String>((
  ref,
  hash,
) async {
  final apiService = ref.watch(qbApiServiceProvider);
  final connectionState = ref.watch(connectionProvider);

  if (!connectionState.isConnected) return [];

  return await apiService.getTorrentFiles(hash);
});

/// Provider for torrent peers
final torrentPeersProvider = FutureProvider.family<List<Peer>, String>((
  ref,
  hash,
) async {
  final apiService = ref.watch(qbApiServiceProvider);
  final connectionState = ref.watch(connectionProvider);

  if (!connectionState.isConnected) return [];

  return await apiService.getTorrentPeers(hash);
});

/// Provider for torrent trackers
final torrentTrackersProvider = FutureProvider.family<List<Tracker>, String>((
  ref,
  hash,
) async {
  final apiService = ref.watch(qbApiServiceProvider);
  final connectionState = ref.watch(connectionProvider);

  if (!connectionState.isConnected) return [];

  return await apiService.getTorrentTrackers(hash);
});

/// Provider for global transfer info
final transferInfoProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final apiService = ref.watch(qbApiServiceProvider);
  final connectionState = ref.watch(connectionProvider);

  if (!connectionState.isConnected) return null;

  return await apiService.getTransferInfo();
});

/// Provider for active downloads count (for navigation badge)
final activeDownloadsCountProvider = Provider<int>((ref) {
  final torrents = ref.watch(torrentListProvider).torrents;
  return torrents.where((t) => t.isDownloading).length;
});

/// Provider for total torrents count
final totalTorrentsCountProvider = Provider<int>((ref) {
  return ref.watch(torrentListProvider).torrents.length;
});

/// Provider for errored torrents count
final erroredTorrentsCountProvider = Provider<int>((ref) {
  final torrents = ref.watch(torrentListProvider).torrents;
  return torrents.where((t) => t.hasError).length;
});
