import 'package:flutter/material.dart';

import '../utils/constants.dart';
import '../utils/platform_utils.dart';

/// Application settings model
class AppSettings {
  // Connection settings
  final String host;
  final int port;
  final String username;
  final String password;
  final String qbittorrentPath;
  final bool autoStartQBittorrent;

  // Download settings
  final String defaultSavePath;
  final int downloadSpeedLimit; // bytes per second, 0 = unlimited
  final int uploadSpeedLimit; // bytes per second, 0 = unlimited
  @Deprecated('Not implemented - kept for backwards compatibility')
  final int maxConnections; // TODO: Implement or remove in future version

  // App settings
  final ThemeMode themeMode;
  final int updateIntervalSeconds; // Polling interval when downloads are active
  final int
  idlePollingIntervalSeconds; // Polling interval when no active downloads
  final bool
  useAdaptivePolling; // Whether to use adaptive polling based on activity
  final bool stopSeedingOnComplete;
  final TorrentFilter defaultFilter;
  final TorrentSort defaultSort;
  final bool sortAscending;

  // Playback settings (Stremio-inspired)
  final bool bingeWatchingEnabled; // Auto-play next episode
  final int nextEpisodeCountdownSeconds; // Seconds before end to show popup

  // External API keys (user-provided; not shipped in source)
  final String tmdbApiKey;

  AppSettings({
    this.host = AppConstants.defaultHost,
    this.port = AppConstants.defaultPort,
    this.username = AppConstants.defaultUsername,
    this.password = AppConstants.defaultPassword,
    String? qbittorrentPath,
    this.autoStartQBittorrent = true,
    String? defaultSavePath,
    this.downloadSpeedLimit = 0,
    this.uploadSpeedLimit = 0,
    this.maxConnections = 500, // Deprecated, kept for backwards compat
    this.themeMode = ThemeMode.system,
    this.updateIntervalSeconds = 2,
    this.idlePollingIntervalSeconds = 10,
    this.useAdaptivePolling = true,
    this.stopSeedingOnComplete = true,
    this.defaultFilter = TorrentFilter.all,
    this.defaultSort = TorrentSort.addedOn,
    this.sortAscending = false,
    this.bingeWatchingEnabled = true,
    this.nextEpisodeCountdownSeconds = 30,
    this.tmdbApiKey = '',
  }) : qbittorrentPath =
           qbittorrentPath ?? PlatformUtils.getDefaultQBittorrentPath(),
       defaultSavePath =
           defaultSavePath ?? PlatformUtils.getDefaultDownloadPath();

  /// Get the full API base URL
  String get apiBaseUrl => 'http://$host:$port';

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      host: json['host'] as String? ?? AppConstants.defaultHost,
      port: json['port'] as int? ?? AppConstants.defaultPort,
      username: json['username'] as String? ?? AppConstants.defaultUsername,
      password: json['password'] as String? ?? AppConstants.defaultPassword,
      qbittorrentPath: json['qbittorrent_path'] as String?,
      autoStartQBittorrent: json['auto_start_qbittorrent'] as bool? ?? true,
      defaultSavePath: json['default_save_path'] as String?,
      downloadSpeedLimit: json['download_speed_limit'] as int? ?? 0,
      uploadSpeedLimit: json['upload_speed_limit'] as int? ?? 0,
      maxConnections: json['max_connections'] as int? ?? 500,
      themeMode: ThemeMode.values[json['theme_mode'] as int? ?? 0],
      updateIntervalSeconds: json['update_interval_seconds'] as int? ?? 2,
      idlePollingIntervalSeconds:
          json['idle_polling_interval_seconds'] as int? ?? 10,
      useAdaptivePolling: json['use_adaptive_polling'] as bool? ?? true,
      stopSeedingOnComplete: json['stop_seeding_on_complete'] as bool? ?? true,
      defaultFilter: TorrentFilter.values[json['default_filter'] as int? ?? 0],
      defaultSort: TorrentSort.values[json['default_sort'] as int? ?? 5],
      sortAscending: json['sort_ascending'] as bool? ?? false,
      bingeWatchingEnabled: json['binge_watching_enabled'] as bool? ?? true,
      nextEpisodeCountdownSeconds:
          json['next_episode_countdown_seconds'] as int? ?? 30,
      tmdbApiKey: json['tmdb_api_key'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'host': host,
      'port': port,
      'username': username,
      'password': password,
      'qbittorrent_path': qbittorrentPath,
      'auto_start_qbittorrent': autoStartQBittorrent,
      'default_save_path': defaultSavePath,
      'download_speed_limit': downloadSpeedLimit,
      'upload_speed_limit': uploadSpeedLimit,
      'max_connections': maxConnections,
      'theme_mode': themeMode.index,
      'update_interval_seconds': updateIntervalSeconds,
      'idle_polling_interval_seconds': idlePollingIntervalSeconds,
      'use_adaptive_polling': useAdaptivePolling,
      'stop_seeding_on_complete': stopSeedingOnComplete,
      'default_filter': defaultFilter.index,
      'default_sort': defaultSort.index,
      'sort_ascending': sortAscending,
      'binge_watching_enabled': bingeWatchingEnabled,
      'next_episode_countdown_seconds': nextEpisodeCountdownSeconds,
      'tmdb_api_key': tmdbApiKey,
    };
  }

  AppSettings copyWith({
    String? host,
    int? port,
    String? username,
    String? password,
    String? qbittorrentPath,
    bool? autoStartQBittorrent,
    String? defaultSavePath,
    int? downloadSpeedLimit,
    int? uploadSpeedLimit,
    int? maxConnections,
    ThemeMode? themeMode,
    int? updateIntervalSeconds,
    int? idlePollingIntervalSeconds,
    bool? useAdaptivePolling,
    bool? stopSeedingOnComplete,
    TorrentFilter? defaultFilter,
    TorrentSort? defaultSort,
    bool? sortAscending,
    bool? bingeWatchingEnabled,
    int? nextEpisodeCountdownSeconds,
    String? tmdbApiKey,
  }) {
    return AppSettings(
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      qbittorrentPath: qbittorrentPath ?? this.qbittorrentPath,
      autoStartQBittorrent: autoStartQBittorrent ?? this.autoStartQBittorrent,
      defaultSavePath: defaultSavePath ?? this.defaultSavePath,
      downloadSpeedLimit: downloadSpeedLimit ?? this.downloadSpeedLimit,
      uploadSpeedLimit: uploadSpeedLimit ?? this.uploadSpeedLimit,
      maxConnections: maxConnections ?? this.maxConnections,
      themeMode: themeMode ?? this.themeMode,
      updateIntervalSeconds:
          updateIntervalSeconds ?? this.updateIntervalSeconds,
      idlePollingIntervalSeconds:
          idlePollingIntervalSeconds ?? this.idlePollingIntervalSeconds,
      useAdaptivePolling: useAdaptivePolling ?? this.useAdaptivePolling,
      stopSeedingOnComplete:
          stopSeedingOnComplete ?? this.stopSeedingOnComplete,
      defaultFilter: defaultFilter ?? this.defaultFilter,
      defaultSort: defaultSort ?? this.defaultSort,
      sortAscending: sortAscending ?? this.sortAscending,
      bingeWatchingEnabled: bingeWatchingEnabled ?? this.bingeWatchingEnabled,
      nextEpisodeCountdownSeconds:
          nextEpisodeCountdownSeconds ?? this.nextEpisodeCountdownSeconds,
      tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettings &&
          runtimeType == other.runtimeType &&
          host == other.host &&
          port == other.port &&
          username == other.username &&
          password == other.password &&
          qbittorrentPath == other.qbittorrentPath &&
          autoStartQBittorrent == other.autoStartQBittorrent &&
          defaultSavePath == other.defaultSavePath &&
          downloadSpeedLimit == other.downloadSpeedLimit &&
          uploadSpeedLimit == other.uploadSpeedLimit &&
          maxConnections == other.maxConnections &&
          themeMode == other.themeMode &&
          updateIntervalSeconds == other.updateIntervalSeconds &&
          idlePollingIntervalSeconds == other.idlePollingIntervalSeconds &&
          useAdaptivePolling == other.useAdaptivePolling &&
          stopSeedingOnComplete == other.stopSeedingOnComplete &&
          defaultFilter == other.defaultFilter &&
          defaultSort == other.defaultSort &&
          sortAscending == other.sortAscending &&
          bingeWatchingEnabled == other.bingeWatchingEnabled &&
          nextEpisodeCountdownSeconds == other.nextEpisodeCountdownSeconds &&
          tmdbApiKey == other.tmdbApiKey;

  @override
  int get hashCode => Object.hashAll([
    host,
    port,
    username,
    password,
    qbittorrentPath,
    autoStartQBittorrent,
    defaultSavePath,
    downloadSpeedLimit,
    uploadSpeedLimit,
    maxConnections,
    themeMode,
    updateIntervalSeconds,
    idlePollingIntervalSeconds,
    useAdaptivePolling,
    stopSeedingOnComplete,
    defaultFilter,
    defaultSort,
    sortAscending,
    bingeWatchingEnabled,
    nextEpisodeCountdownSeconds,
    tmdbApiKey,
  ]);
}
