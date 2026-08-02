import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// Result of [loadPrefsSafe]: the usable [SharedPreferences] instance, plus a
/// flag indicating whether the previous file was unreadable and got reset.
/// Callers can use [recovered] to surface a one-time toast on first frame.
class PrefsLoadResult {
  PrefsLoadResult(this.prefs, {required this.recovered});

  final SharedPreferences prefs;
  final bool recovered;
}

/// Load `SharedPreferences`, recovering from a corrupted on-disk file.
///
/// The bug: when the host OS crashes (BSOD) while MediaHub is running, NTFS
/// can recover `shared_preferences.json` as all-zero bytes of the original
/// length. The shared_preferences plugin then throws on JSON parse, which —
/// because the call sits before `runApp()` — leaves the process running with
/// no window and no error visible to the user.
///
/// Recovery: rename the bad file aside (so it can be inspected later) and
/// fall through to a fresh, empty store.
Future<PrefsLoadResult> loadPrefsSafe() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return PrefsLoadResult(prefs, recovered: false);
  } catch (e) {
    AppLog.e('[Prefs] SharedPreferences.getInstance failed: $e');
    await _quarantineCorruptedFile();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    return PrefsLoadResult(prefs, recovered: true);
  }
}

/// Copy a single unreadable preferences value aside before the caller falls
/// back to an empty default.
///
/// The failure mode this exists for: a corrupt JSON blob throws on decode, the
/// caller substitutes an empty collection, and the very next successful save
/// overwrites the only copy of the user's favourites or watchlist. Writing the
/// raw string out first makes a bad parse cost a session rather than the data.
///
/// Best-effort and fire-and-forget — callers run inside synchronous provider
/// `build()` methods and cannot block on disk I/O.
void quarantinePrefsValue(String key, String? raw, Object error) {
  AppLog.e(
    '[Prefs] Unreadable value for "$key", falling back to empty: $error',
  );
  if (raw == null || raw.isEmpty) return;
  unawaited(_writeQuarantine(key, raw));
}

Future<void> _writeQuarantine(String key, String raw) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final quarantine = Directory('${dir.path}/corrupted');
    await quarantine.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${quarantine.path}/$key-$stamp.json');
    await file.writeAsString(raw);
    AppLog.w('[Prefs] Quarantined unreadable "$key" to ${file.path}');
  } catch (e) {
    AppLog.e('[Prefs] Failed to quarantine "$key": $e');
  }
}

Future<void> _quarantineCorruptedFile() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/shared_preferences.json');
    if (await file.exists()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final backup = '${file.path}.corrupted-$stamp.bak';
      await file.rename(backup);
      AppLog.w('[Prefs] Quarantined corrupted prefs to $backup');
    }
  } catch (e) {
    AppLog.e('[Prefs] Failed to quarantine corrupted prefs: $e');
  }
}
