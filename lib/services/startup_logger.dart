import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Append-only log written next to `shared_preferences.json` so that startup
/// failures (which produce no UI and no console output in a release build) are
/// at least diagnosable from disk.
///
/// Best-effort: every operation swallows its own errors. If logging fails we
/// must not let that failure mask the original startup problem.
class StartupLogger {
  StartupLogger._(this._file);

  final File? _file;

  static Future<StartupLogger> open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/mediahub.log');
      if (await file.exists() && await file.length() > 256 * 1024) {
        await file.delete();
      }
      return StartupLogger._(file);
    } catch (_) {
      return StartupLogger._(null);
    }
  }

  Future<void> log(String message) async {
    final file = _file;
    if (file == null) return;
    try {
      final ts = DateTime.now().toIso8601String();
      await file.writeAsString(
        '[$ts] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }
}
