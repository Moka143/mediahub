import 'dart:io';

import 'constants.dart';

/// Last path segment, whichever platform produced the string.
///
/// Deliberately separator-agnostic rather than separator-*aware*:
///
///   * `path.basename` follows the host platform, so on macOS it treats `\`
///     as an ordinary character — and qBittorrent running on Windows hands
///     back `Show\S01E01.mkv`, which would survive whole.
///   * `split('/').last` — which six call sites used — returns the entire
///     string for any Windows path, so the "file name" becomes
///     `C:\Users\me\Downloads\Show.S01E01.mkv`. That silently poisons
///     anything derived from it: the TMDB movie lookup in the watched-sync
///     cleans a full path instead of a title and matches nothing, so movie
///     watched-state stops syncing on Windows with no error anywhere.
///
/// Both separators, always, because these strings cross platforms: a torrent
/// created on Windows can be read on macOS and vice versa.
String basenameOf(String path) {
  final index = path.lastIndexOf(RegExp(r'[\\/]'));
  return index < 0 ? path : path.substring(index + 1);
}

/// Platform-specific utility functions
class PlatformUtils {
  PlatformUtils._();

  /// Get the default qBittorrent executable path for the current platform
  static String getDefaultQBittorrentPath() {
    if (Platform.isWindows) {
      return QBittorrentPaths.windows;
    } else if (Platform.isLinux) {
      return QBittorrentPaths.linux;
    } else if (Platform.isMacOS) {
      return QBittorrentPaths.macos;
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  /// Get the current platform name
  static String getPlatformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'macos';
    return 'unknown';
  }

  /// Check if qBittorrent exists at the given path
  static Future<bool> qBittorrentExists(String path) async {
    final file = File(path);
    return file.exists();
  }

  /// Expand `%VAR%` placeholders against the process environment.
  ///
  /// Returns null when any referenced variable is missing, so a caller can
  /// skip the candidate rather than probe a path with a literal `%VAR%` in
  /// it. Windows-shaped, but harmless anywhere.
  static String? expandWindowsVars(
    String value, {
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    var missing = false;
    final expanded = value.replaceAllMapped(RegExp(r'%([^%]+)%'), (match) {
      final replacement = env[match.group(1)!];
      if (replacement == null) missing = true;
      return replacement ?? '';
    });
    return missing ? null : expanded;
  }

  /// Candidate qBittorrent locations to try, most likely first.
  ///
  /// Only Windows has more than one: `which` finds qBittorrent on macOS and
  /// Linux, and nothing puts it on `PATH` on Windows.
  static List<String> qBittorrentCandidates({
    Map<String, String>? environment,
  }) {
    if (!Platform.isWindows) return const [];
    final seen = <String>{};
    return [
      for (final candidate in QBittorrentPaths.windowsFallbacks)
        if (expandWindowsVars(candidate, environment: environment)
            case final path?)
          if (seen.add(path.toLowerCase())) path,
    ];
  }

  /// Get the default download directory for the current platform.
  ///
  /// On Windows, `%USERPROFILE%\Downloads` is only right when the folder has
  /// not been redirected. OneDrive's "Back up your folders" moves Downloads
  /// under `%OneDrive%` and leaves nothing behind, so the naive path points
  /// at a directory that does not exist and the library scans nothing. Prefer
  /// whichever candidate is actually on disk.
  static String getDefaultDownloadPath() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';

    if (!Platform.isWindows) return '$home/Downloads';

    final oneDrive = Platform.environment['OneDrive'];
    final candidates = <String>[
      '$home\\Downloads',
      if (oneDrive != null && oneDrive.isNotEmpty) '$oneDrive\\Downloads',
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return candidate;
    }
    return candidates.first;
  }

  /// Hosts that mean "this machine".
  ///
  /// Matters because [QBittorrentProcessService] decides whether to *launch*
  /// qBittorrent from whether its port answers. Probing localhost while the
  /// user has pointed the app at a remote qBittorrent means the local port is
  /// always free, and the health check tries to spawn a local instance every
  /// few seconds.
  static bool isLocalHost(String host) {
    final h = host.trim().toLowerCase();
    return h.isEmpty ||
        h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '::1' ||
        h == '0.0.0.0';
  }

  /// Check if a port is in use by trying to connect to it
  static Future<bool> isPortInUse(int port, {String host = 'localhost'}) async {
    // Try to connect to the port - if successful, something is listening
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      await socket.close();
      return true; // Connection succeeded, port is in use
    } catch (e) {
      return false; // Connection failed, port is free
    }
  }
}
