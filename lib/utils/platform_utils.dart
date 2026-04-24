import 'dart:io';

import 'constants.dart';

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

  /// Get the default download directory for the current platform
  static String getDefaultDownloadPath() {
    final home = Platform.environment['HOME'] ?? 
                 Platform.environment['USERPROFILE'] ?? 
                 '';
    
    if (Platform.isWindows) {
      return '$home\\Downloads';
    } else {
      return '$home/Downloads';
    }
  }

  /// Get command line arguments for starting qBittorrent in headless mode
  static List<String> getQBittorrentArgs() {
    if (Platform.isLinux) {
      // qbittorrent-nox is already headless
      return [];
    } else if (Platform.isMacOS) {
      // macOS qBittorrent with Web UI enabled
      return ['--webui-port=8080'];
    } else if (Platform.isWindows) {
      // Windows: minimize to tray
      return ['--webui-port=8080'];
    }
    return [];
  }

  /// Check if a port is in use by trying to connect to it
  static Future<bool> isPortInUse(int port) async {
    // Try to connect to the port - if successful, something is listening
    try {
      final socket = await Socket.connect(
        'localhost',
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
