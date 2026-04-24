import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/settings.dart';
import '../utils/constants.dart';
import 'local_media_provider.dart';

/// Key for storing settings in SharedPreferences
const _settingsKey = 'app_settings';

/// Provider for SharedPreferences instance
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('SharedPreferences must be overridden in main');
});

/// Provider for app settings
final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// Provider for theme mode derived from settings
final themeModeProvider = Provider<ThemeMode>((ref) {
  return ref.watch(settingsProvider).themeMode;
});

/// Provider for current filter
final currentFilterProvider = NotifierProvider<CurrentFilterNotifier, TorrentFilter>(
  CurrentFilterNotifier.new,
);

/// Provider for current sort
final currentSortProvider = NotifierProvider<CurrentSortNotifier, TorrentSort>(
  CurrentSortNotifier.new,
);

/// Provider for sort ascending
final sortAscendingProvider = NotifierProvider<SortAscendingNotifier, bool>(
  SortAscendingNotifier.new,
);

/// Notifier for current filter
class CurrentFilterNotifier extends Notifier<TorrentFilter> {
  @override
  TorrentFilter build() {
    return ref.watch(settingsProvider).defaultFilter;
  }
  
  void set(TorrentFilter value) => state = value;
}

/// Notifier for current sort
class CurrentSortNotifier extends Notifier<TorrentSort> {
  @override
  TorrentSort build() {
    return ref.watch(settingsProvider).defaultSort;
  }
  
  void set(TorrentSort value) => state = value;
}

/// Notifier for sort ascending
class SortAscendingNotifier extends Notifier<bool> {
  @override
  bool build() {
    return ref.watch(settingsProvider).sortAscending;
  }
  
  void set(bool value) => state = value;
  void toggle() => state = !state;
}

/// Notifier for managing app settings
class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return _loadSettings(prefs);
  }

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  /// Load settings from SharedPreferences
  static AppSettings _loadSettings(SharedPreferences prefs) {
    final jsonString = prefs.getString(_settingsKey);
    if (jsonString != null) {
      try {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        return AppSettings.fromJson(json);
      } catch (e) {
        debugPrint('Error loading settings: $e');
      }
    }
    return AppSettings();
  }

  /// Save current settings to SharedPreferences
  Future<void> _saveSettings() async {
    final jsonString = jsonEncode(state.toJson());
    await _prefs.setString(_settingsKey, jsonString);
  }

  /// Update settings
  Future<void> updateSettings(AppSettings newSettings) async {
    state = newSettings;
    await _saveSettings();
  }

  /// Update host
  Future<void> setHost(String host) async {
    state = state.copyWith(host: host);
    await _saveSettings();
  }

  /// Update port
  Future<void> setPort(int port) async {
    state = state.copyWith(port: port);
    await _saveSettings();
  }

  /// Update username
  Future<void> setUsername(String username) async {
    state = state.copyWith(username: username);
    await _saveSettings();
  }

  /// Update password
  Future<void> setPassword(String password) async {
    state = state.copyWith(password: password);
    await _saveSettings();
  }

  /// Update qBittorrent path
  Future<void> setQBittorrentPath(String path) async {
    state = state.copyWith(qbittorrentPath: path);
    await _saveSettings();
  }

  /// Update auto-start setting
  Future<void> setAutoStartQBittorrent(bool autoStart) async {
    state = state.copyWith(autoStartQBittorrent: autoStart);
    await _saveSettings();
  }

  /// Update default save path
  Future<void> setDefaultSavePath(String path) async {
    state = state.copyWith(defaultSavePath: path);
    await _saveSettings();
    
    // Invalidate media providers to rescan with new path
    ref.invalidate(localMediaStreamProvider);
    ref.invalidate(localMediaScannerProvider);
    ref.invalidate(localMediaFilesProvider);
  }

  /// Update download speed limit
  Future<void> setDownloadSpeedLimit(int limit) async {
    state = state.copyWith(downloadSpeedLimit: limit);
    await _saveSettings();
  }

  /// Update upload speed limit
  Future<void> setUploadSpeedLimit(int limit) async {
    state = state.copyWith(uploadSpeedLimit: limit);
    await _saveSettings();
  }

  /// Update max connections
  Future<void> setMaxConnections(int connections) async {
    state = state.copyWith(maxConnections: connections);
    await _saveSettings();
  }

  /// Update theme mode
  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _saveSettings();
  }

  /// Update update interval (active polling)
  Future<void> setUpdateInterval(int seconds) async {
    state = state.copyWith(updateIntervalSeconds: seconds);
    await _saveSettings();
  }

  /// Update idle polling interval
  Future<void> setIdlePollingInterval(int seconds) async {
    state = state.copyWith(idlePollingIntervalSeconds: seconds);
    await _saveSettings();
  }

  /// Update adaptive polling setting
  Future<void> setUseAdaptivePolling(bool enabled) async {
    state = state.copyWith(useAdaptivePolling: enabled);
    await _saveSettings();
  }

  /// Update stop seeding on complete
  Future<void> setStopSeedingOnComplete(bool enabled) async {
    state = state.copyWith(stopSeedingOnComplete: enabled);
    await _saveSettings();
  }

  /// Update default filter
  Future<void> setDefaultFilter(TorrentFilter filter) async {
    state = state.copyWith(defaultFilter: filter);
    await _saveSettings();
  }

  /// Update default sort
  Future<void> setDefaultSort(TorrentSort sort) async {
    state = state.copyWith(defaultSort: sort);
    await _saveSettings();
  }

  /// Update sort ascending
  Future<void> setSortAscending(bool ascending) async {
    state = state.copyWith(sortAscending: ascending);
    await _saveSettings();
  }

  /// Update binge watching enabled
  Future<void> setBingeWatchingEnabled(bool enabled) async {
    state = state.copyWith(bingeWatchingEnabled: enabled);
    await _saveSettings();
  }

  /// Update next episode countdown seconds
  Future<void> setNextEpisodeCountdownSeconds(int seconds) async {
    state = state.copyWith(nextEpisodeCountdownSeconds: seconds);
    await _saveSettings();
  }

  /// Update TMDB API key (user-provided via onboarding/settings)
  Future<void> setTmdbApiKey(String apiKey) async {
    state = state.copyWith(tmdbApiKey: apiKey.trim());
    await _saveSettings();
  }

  /// Reset settings to defaults
  Future<void> resetToDefaults() async {
    state = AppSettings();
    await _saveSettings();
  }
}

/// Convenience: true when the user has entered a non-empty TMDB key.
final hasTmdbApiKeyProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).tmdbApiKey.isNotEmpty;
});

/// Provider for binge watching enabled
final bingeWatchingEnabledProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).bingeWatchingEnabled;
});

/// Provider for next episode countdown seconds
final nextEpisodeCountdownSecondsProvider = Provider<int>((ref) {
  return ref.watch(settingsProvider).nextEpisodeCountdownSeconds;
});
