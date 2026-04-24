/// Application-wide constants
class AppConstants {
  AppConstants._();

  // App Info
  static const String appName = 'MediaHub';
  static const String appVersion = '1.0.0';

  // qBittorrent API defaults
  static const String defaultHost = 'localhost';
  static const int defaultPort = 8080;
  static const String defaultUsername = 'admin';
  static const String defaultPassword = '';  // Empty is qBittorrent's default

  // Polling intervals
  static const Duration defaultPollingInterval = Duration(seconds: 2);
  static const Duration connectionCheckInterval = Duration(seconds: 5);

  // Retry settings
  static const int maxRetryAttempts = 5;
  static const Duration initialRetryDelay = Duration(seconds: 1);
  static const double retryBackoffMultiplier = 2.0;

  // UI
  static const double minWindowWidth = 800;
  static const double minWindowHeight = 600;
}

/// qBittorrent executable paths for each platform
class QBittorrentPaths {
  QBittorrentPaths._();

  static const String windows = r'C:\Program Files\qBittorrent\qbittorrent.exe';
  static const String linux = '/usr/bin/qbittorrent-nox';
  static const String macos = '/Applications/qBittorrent.app/Contents/MacOS/qBittorrent';
}

/// Torrent state constants from qBittorrent API
class TorrentState {
  TorrentState._();

  static const String error = 'error';
  static const String missingFiles = 'missingFiles';
  static const String uploading = 'uploading';
  static const String pausedUP = 'pausedUP';
  static const String stoppedUP = 'stoppedUP';  // v5.x state
  static const String queuedUP = 'queuedUP';
  static const String stalledUP = 'stalledUP';
  static const String checkingUP = 'checkingUP';
  static const String forcedUP = 'forcedUP';
  static const String allocating = 'allocating';
  static const String downloading = 'downloading';
  static const String metaDL = 'metaDL';
  static const String pausedDL = 'pausedDL';
  static const String stoppedDL = 'stoppedDL';  // v5.x state
  static const String queuedDL = 'queuedDL';
  static const String stalledDL = 'stalledDL';
  static const String checkingDL = 'checkingDL';
  static const String forcedDL = 'forcedDL';
  static const String checkingResumeData = 'checkingResumeData';
  static const String moving = 'moving';
  static const String unknown = 'unknown';

  /// Returns true if the torrent is in a downloading state
  static bool isDownloading(String state) {
    return [downloading, metaDL, queuedDL, stalledDL, checkingDL, forcedDL, allocating]
        .contains(state);
  }

  /// Returns true if the torrent is in an uploading/seeding state
  static bool isSeeding(String state) {
    return [uploading, queuedUP, stalledUP, checkingUP, forcedUP].contains(state);
  }

  /// Returns true if the torrent is paused/stopped
  static bool isPaused(String state) {
    return [pausedDL, pausedUP, stoppedDL, stoppedUP].contains(state);
  }

  /// Returns true if the torrent has completed downloading
  static bool isCompleted(String state) {
    return [uploading, pausedUP, stoppedUP, queuedUP, stalledUP, checkingUP, forcedUP].contains(state);
  }

  /// Returns true if the torrent has an error
  static bool hasError(String state) {
    return [error, missingFiles].contains(state);
  }
}

/// Filter options for torrent list
enum TorrentFilter {
  all('All'),
  downloading('Downloading'),
  seeding('Seeding'),
  completed('Completed'),
  paused('Paused'),
  active('Active'),
  inactive('Inactive'),
  errored('Errored');

  final String label;
  const TorrentFilter(this.label);
}

/// Sort options for torrent list
enum TorrentSort {
  name('Name'),
  size('Size'),
  progress('Progress'),
  dlspeed('Download Speed'),
  upspeed('Upload Speed'),
  addedOn('Added Date'),
  eta('ETA');

  final String label;
  const TorrentSort(this.label);
}

/// File priority levels
enum FilePriority {
  doNotDownload(0, 'Do not download'),
  normal(1, 'Normal'),
  high(6, 'High'),
  maximum(7, 'Maximum');

  final int value;
  final String label;
  const FilePriority(this.value, this.label);

  static FilePriority fromValue(int value) {
    return FilePriority.values.firstWhere(
      (p) => p.value == value,
      orElse: () => FilePriority.normal,
    );
  }
}
