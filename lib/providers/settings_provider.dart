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
final currentFilterProvider =
    NotifierProvider<CurrentFilterNotifier, TorrentFilter>(
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

/// Build-time TMDB v4 Read Access Token bundled with the release. Pass via:
///   `flutter build … --dart-define=TMDB_READ_ACCESS_TOKEN=<token>`
/// or set it in a CI release pipeline. Falls back to the older
/// `TMDB_API_KEY` define for repos that haven't updated their secret yet,
/// but expects a v4 Bearer token (JWT) — a v3 32-char hex key won't
/// authenticate as Bearer.
const String _bundledTokenNew = String.fromEnvironment(
  'TMDB_READ_ACCESS_TOKEN',
  defaultValue: '',
);
const String _bundledTokenLegacy = String.fromEnvironment(
  'TMDB_API_KEY',
  defaultValue: '',
);
final String bundledTmdbReadAccessToken = _bundledTokenNew.isNotEmpty
    ? _bundledTokenNew
    : _bundledTokenLegacy;

/// Heuristic: a v4 access token is a JWT and starts with the `eyJ`
/// base64-encoded header. v3 api_keys are 32 hex chars and don't.
bool _looksLikeV4Token(String value) => value.startsWith('eyJ');

/// The TMDB Bearer token that should actually be used for requests.
///
/// Resolution priority:
///   1. User access token (from v4 OAuth — picked up via [tmdbSessionProvider]
///      and applied by tmdb_account_provider's service provider).
///   2. User-pasted read access token from Settings (the existing
///      `settings.tmdbApiKey` field, now semantically a v4 read token).
///   3. Bundled read access token from `--dart-define`.
///
/// Note: when signed in, the user token overrides the read token —
/// tmdb_account_provider's [TmdbSessionNotifier] persists the user token
/// to its own pref keys; [tmdbAccountServiceProvider] selects the right
/// Bearer at request time.
final effectiveTmdbAccessTokenProvider = Provider<String>((ref) {
  // We don't pull the session here to avoid a dependency cycle
  // (tmdb_account_provider already imports this file). The session-aware
  // service provider lives in tmdb_account_provider and picks the user
  // token explicitly.
  final userOverride = ref.watch(settingsProvider).tmdbApiKey.trim();
  if (userOverride.isNotEmpty && _looksLikeV4Token(userOverride)) {
    return userOverride;
  }
  return bundledTmdbReadAccessToken;
});

/// True when *any* TMDB Bearer token is available (user override OR
/// bundled default). Drives onboarding and account-section gating.
final hasTmdbApiKeyProvider = Provider<bool>((ref) {
  return ref.watch(effectiveTmdbAccessTokenProvider).isNotEmpty;
});

/// True when the app is running with the bundled token (no valid user
/// override). Used in Settings to label the field.
final isUsingBundledTmdbKeyProvider = Provider<bool>((ref) {
  final override = ref.watch(settingsProvider).tmdbApiKey.trim();
  final hasValidOverride = override.isNotEmpty && _looksLikeV4Token(override);
  return !hasValidOverride && bundledTmdbReadAccessToken.isNotEmpty;
});

const _onboardedKey = 'has_completed_onboarding';

/// Tracks whether the user has been past the onboarding screen at least once.
/// Set to true when the user signs in, saves their own key, OR explicitly
/// skips. Used by [SplashScreen] to decide whether to route to onboarding.
class OnboardingCompletedNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return prefs.getBool(_onboardedKey) ?? false;
  }

  Future<void> markCompleted() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_onboardedKey, true);
    state = true;
  }

  Future<void> reset() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.remove(_onboardedKey);
    state = false;
  }
}

final hasCompletedOnboardingProvider =
    NotifierProvider<OnboardingCompletedNotifier, bool>(
      OnboardingCompletedNotifier.new,
    );

/// Provider for binge watching enabled
final bingeWatchingEnabledProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).bingeWatchingEnabled;
});

/// Provider for next episode countdown seconds
final nextEpisodeCountdownSecondsProvider = Provider<int>((ref) {
  return ref.watch(settingsProvider).nextEpisodeCountdownSeconds;
});
