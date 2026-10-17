import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/constants.dart';
import 'app_logger.dart';
import 'http_client.dart';

/// A published MediaHub release with a Windows installer.
@immutable
class AppRelease {
  const AppRelease({
    required this.version,
    required this.installerName,
    required this.installerUrl,
    required this.checksumUrl,
  });

  /// "0.9.0" — no leading "v".
  final String version;
  final String installerName;
  final String installerUrl;

  /// The `.sha256` file CI publishes beside the installer. Null for a
  /// release from before the updater existed, which is then not offered:
  /// an installer that cannot be checked is not run.
  final String? checksumUrl;
}

/// Why an update could not be downloaded or started, in words for a person.
class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Whether [candidate] is a later version than [current].
///
/// Both are `major.minor.patch`; a leading "v" and anything after a "-" or
/// "+" are ignored. A version that does not parse is never newer, so a
/// malformed tag cannot trigger an update.
bool isNewerVersion(String candidate, String current) {
  List<int>? parts(String v) {
    final core = v
        .trim()
        .replaceFirst(RegExp('^v'), '')
        .split(RegExp('[-+]'))[0];
    final numbers = core.split('.').map(int.tryParse).toList();
    if (numbers.length != 3 || numbers.contains(null)) return null;
    return numbers.cast<int>();
  }

  final a = parts(candidate);
  final b = parts(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

/// The Windows installer in GitHub's `releases/latest` answer, or null when
/// it has none.
///
/// Matched by name — `mediahub-<version>-windows-setup.exe`, what
/// `windows/installer/mediahub.iss` produces — so the MSIX beside it is
/// never picked.
AppRelease? parseLatestRelease(Map<String, dynamic> json) {
  final tag = json['tag_name'];
  final assets = json['assets'];
  if (tag is! String || assets is! List) return null;

  String? urlOf(bool Function(String name) wanted) {
    for (final asset in assets.whereType<Map<String, dynamic>>()) {
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is String && url is String && wanted(name)) return url;
    }
    return null;
  }

  final installer = RegExp(r'^mediahub-[\d.]+-windows-setup\.exe$');
  String? installerName;
  final installerUrl = urlOf((name) {
    if (!installer.hasMatch(name)) return false;
    installerName = name;
    return true;
  });
  if (installerUrl == null || installerName == null) return null;

  return AppRelease(
    version: tag.replaceFirst(RegExp('^v'), ''),
    installerName: installerName!,
    installerUrl: installerUrl,
    checksumUrl: urlOf((name) => name == '$installerName.sha256'),
  );
}

/// The SHA-256 in a checksum file: its first word, as written by
/// `sha256sum` and by the release workflow. Null when there is none.
String? parseChecksum(String text) {
  final first = text.trim().split(RegExp(r'\s+')).first.toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(first) ? first : null;
}

/// Finds, fetches and starts a newer Windows installer.
///
/// Only the network and the process are here; when to check, and what the
/// user sees, is `AppUpdateNotifier`'s.
class AppUpdateService {
  AppUpdateService({
    Dio? dio,
    Future<Directory> Function()? downloadDir,
    Future<void> Function(String executable, List<String> arguments)? start,
  }) : _dio =
           dio ??
           buildJsonDio(
             baseUrl: 'https://api.github.com',
             connectTimeout: const Duration(seconds: 10),
             receiveTimeout: const Duration(seconds: 30),
             headers: const {'Accept': 'application/vnd.github+json'},
           ),
       _downloadDir = downloadDir ?? getTemporaryDirectory,
       _start = start ?? _startDetached;

  final Dio _dio;
  final Future<Directory> Function() _downloadDir;
  final Future<void> Function(String executable, List<String> arguments) _start;

  /// What the installer is started with.
  ///
  ///  * `/SILENT` — a progress window, no wizard pages to click through;
  ///  * `/CLOSEAPPLICATIONS` — closes this app if it is still running, so
  ///    its files can be replaced;
  ///  * `/UPDATE=1` — the installer starts the new version when it is done
  ///    (see `IsAppUpdate` in `mediahub.iss`), which a silent install
  ///    otherwise skips.
  static const List<String> installerArguments = [
    '/SILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/CLOSEAPPLICATIONS',
    '/UPDATE=1',
  ];

  /// Release assets are files, not API documents: the client's default
  /// `Accept` asks for JSON.
  static const Map<String, String> _binary = {
    'Accept': 'application/octet-stream',
  };

  static Future<void> _startDetached(String executable, List<String> args) =>
      Process.start(executable, args, mode: ProcessStartMode.detached);

  /// The latest release, when it is newer than this build and can be
  /// checked; null otherwise.
  Future<AppRelease?> newerRelease() async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/repos/${AppConstants.releaseRepo}/releases/latest',
    );
    final data = response.data;
    if (data == null) return null;
    final release = parseLatestRelease(data);
    if (release == null || release.checksumUrl == null) return null;
    if (!isNewerVersion(release.version, AppConstants.appVersion)) {
      return null;
    }
    return release;
  }

  /// Download [release]'s installer and check it against its published
  /// SHA-256. A file that does not match is deleted, never returned.
  Future<File> download(
    AppRelease release, {
    void Function(double fraction)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final checksumUrl = release.checksumUrl;
    if (checksumUrl == null) {
      throw const AppUpdateException("This update can't be verified.");
    }
    final checksumText = await _dio.get<String>(
      checksumUrl,
      options: Options(responseType: ResponseType.plain, headers: _binary),
      cancelToken: cancelToken,
    );
    final expected = parseChecksum(checksumText.data ?? '');
    if (expected == null) {
      throw const AppUpdateException("This update can't be verified.");
    }

    final dir = await _downloadDir();
    final file = File(p.join(dir.path, release.installerName));
    await _dio.download(
      release.installerUrl,
      file.path,
      options: Options(headers: _binary),
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call(received / total);
      },
    );

    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual != expected) {
      AppLog.w(
        '[Update] checksum mismatch for ${release.installerName}: '
        'expected $expected, got $actual',
      );
      await file.delete();
      throw const AppUpdateException(
        'The download was damaged. Try again in a moment.',
      );
    }
    return file;
  }

  /// Start the installer on its own, so it outlives this process — which
  /// must quit next for its files to be replaced.
  Future<void> launch(File installer) =>
      _start(installer.path, installerArguments);
}
