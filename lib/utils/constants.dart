/// Application-wide constants
class AppConstants {
  AppConstants._();

  // App Info
  static const String appName = 'MediaHub';

  /// Shown in Settings → About. Must match `version:` in pubspec.yaml —
  /// reading the real one needs `package_info_plus`, which is not worth a
  /// dependency for a single string.
  ///
  /// It drifted to 0.4.1 while pubspec said 0.5.0, so About reported a
  /// version that had not shipped for two releases. `app_version_test.dart`
  /// now fails the build when the two disagree, which is the only thing that
  /// keeps a hand-copied constant honest.
  static const String appVersion = '0.8.0';

  // Built-in engine (rqbit) defaults.
  //
  // Loopback only, and not configurable to anything else: rqbit's HTTP API is
  // unauthenticated, so binding it anywhere reachable would hand torrent
  // control — including save paths — to the local network.
  static const String rqbitHost = '127.0.0.1';

  /// Port the bundled engine listens on. High and unregistered to stay out of
  /// the way of anything the user already runs; overridable in Settings for
  /// the case where it still clashes.
  static const int defaultRqbitPort = 3030;

  // qBittorrent API defaults
  static const String defaultHost = 'localhost';
  static const int defaultPort = 8080;
  static const String defaultUsername = 'admin';
  static const String defaultPassword = ''; // Empty is qBittorrent's default

  // Polling intervals. The torrent list's own intervals come from
  // AppSettings (active / idle), not from here.
  static const Duration connectionCheckInterval = Duration(seconds: 5);

  // Retry settings
  static const int maxRetryAttempts = 5;
  static const Duration initialRetryDelay = Duration(seconds: 1);
  static const double retryBackoffMultiplier = 2.0;

  // UI
  /// The smallest logical viewport the desktop layout is designed for.
  ///
  /// NOT the window minimum — see [hardMinWindowWidth]. Below this, `UiScale`
  /// (lib/design/ui_scale.dart) scales the whole UI down so the layout keeps
  /// its proportions instead of clipping.
  static const double minWindowWidth = 800;
  static const double minWindowHeight = 600;

  /// The smallest window the OS is allowed to enforce.
  ///
  /// Deliberately far below the design floor. window_manager turns
  /// `WindowOptions.minimumSize` into `ptMinTrackSize` in *physical* pixels by
  /// multiplying it by the current monitor's scale, so a 600-logical floor is
  /// 1350 physical at 225% and 1800 at 300% — taller than the work area of a
  /// 1080p panel. That is a window the user cannot resize to fit their own
  /// screen, which is how a high-DPI external monitor broke the layout.
  ///
  /// Exactly [minWindowWidth]/[minWindowHeight] times `UiScale.minScale`, so
  /// the smallest window Windows will allow is still the smallest window that
  /// can render the full 800x600 desktop layout.
  static const double hardMinWindowWidth = 400;
  static const double hardMinWindowHeight = 300;
}

/// qBittorrent executable paths for each platform
class QBittorrentPaths {
  QBittorrentPaths._();

  static const String windows = r'C:\Program Files\qBittorrent\qbittorrent.exe';
  static const String linux = '/usr/bin/qbittorrent-nox';
  static const String macos =
      '/Applications/qBittorrent.app/Contents/MacOS/qBittorrent';

  /// Where else qBittorrent is commonly installed on Windows.
  ///
  /// The default above is only right for a 64-bit install to the default
  /// location. Nothing puts qBittorrent on `PATH` on Windows, so the `which`
  /// fallback that rescues macOS and Linux finds nothing — leaving anyone
  /// with a 32-bit build, a per-user install, or a second drive staring at
  /// "qBittorrent executable not found" with no idea that the fix is to type
  /// a path into Settings.
  ///
  /// `%…%` placeholders are expanded against the environment at lookup time;
  /// an entry whose variable is unset is skipped.
  static const List<String> windowsFallbacks = [
    r'%ProgramFiles%\qBittorrent\qbittorrent.exe',
    r'%ProgramFiles(x86)%\qBittorrent\qbittorrent.exe',
    r'%LOCALAPPDATA%\Programs\qBittorrent\qbittorrent.exe',
    r'%LOCALAPPDATA%\qBittorrent\qbittorrent.exe',
    r'%USERPROFILE%\scoop\apps\qbittorrent\current\qbittorrent.exe',
    r'C:\Program Files\qBittorrent\qbittorrent.exe',
    r'C:\Program Files (x86)\qBittorrent\qbittorrent.exe',
  ];
}

/// Torrent state constants from qBittorrent API
class TorrentState {
  TorrentState._();

  static const String error = 'error';
  static const String missingFiles = 'missingFiles';
  static const String uploading = 'uploading';
  static const String pausedUP = 'pausedUP';
  static const String stoppedUP = 'stoppedUP'; // v5.x state
  static const String queuedUP = 'queuedUP';
  static const String stalledUP = 'stalledUP';
  static const String checkingUP = 'checkingUP';
  static const String forcedUP = 'forcedUP';
  static const String allocating = 'allocating';
  static const String downloading = 'downloading';
  static const String metaDL = 'metaDL';
  static const String pausedDL = 'pausedDL';
  static const String stoppedDL = 'stoppedDL'; // v5.x state
  static const String queuedDL = 'queuedDL';
  static const String stalledDL = 'stalledDL';
  static const String checkingDL = 'checkingDL';
  static const String forcedDL = 'forcedDL';
  static const String checkingResumeData = 'checkingResumeData';
  static const String moving = 'moving';
  static const String unknown = 'unknown';

  /// Returns true if the torrent is in a downloading state
  static bool isDownloading(String state) {
    return [
      downloading,
      metaDL,
      queuedDL,
      stalledDL,
      checkingDL,
      forcedDL,
      allocating,
    ].contains(state);
  }

  /// Returns true if the torrent is in an uploading/seeding state
  static bool isSeeding(String state) {
    return [
      uploading,
      queuedUP,
      stalledUP,
      checkingUP,
      forcedUP,
    ].contains(state);
  }

  /// Returns true if the torrent is paused/stopped
  static bool isPaused(String state) {
    return [pausedDL, pausedUP, stoppedDL, stoppedUP].contains(state);
  }

  /// Returns true if the torrent has completed downloading
  static bool isCompleted(String state) {
    return [
      uploading,
      pausedUP,
      stoppedUP,
      queuedUP,
      stalledUP,
      checkingUP,
      forcedUP,
    ].contains(state);
  }

  /// Returns true if the torrent has an error
  static bool hasError(String state) {
    return [error, missingFiles].contains(state);
  }
}

/// Which torrent backend the app drives.
enum TorrentEngineKind {
  /// rqbit, bundled with the app and run headless on loopback. No window, no
  /// tray icon, no notifications, no setup — and it serves files over HTTP
  /// while they download, so nothing has to front the partial file.
  builtin('Built-in engine'),

  /// A qBittorrent the user installs and owns. Kept because it is the only
  /// way to drive an instance on another machine, and because an existing
  /// library should not have to move.
  qbittorrent('qBittorrent');

  final String label;
  const TorrentEngineKind(this.label);

  /// The engine's name as it reads mid-sentence — "Make sure X is running".
  /// [label] is a heading; this is prose, and the two want different casing
  /// and a different article.
  String get sentenceName => switch (this) {
    TorrentEngineKind.builtin => 'the built-in engine',
    TorrentEngineKind.qbittorrent => 'qBittorrent',
  };
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
