import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'startup_logger.dart';

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
Future<PrefsLoadResult> loadPrefsSafe(StartupLogger log) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return PrefsLoadResult(prefs, recovered: false);
  } catch (e) {
    await log.log('SharedPreferences.getInstance failed: $e');
    await _quarantineCorruptedFile(log);
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    return PrefsLoadResult(prefs, recovered: true);
  }
}

Future<void> _quarantineCorruptedFile(StartupLogger log) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/shared_preferences.json');
    if (await file.exists()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final backup = '${file.path}.corrupted-$stamp.bak';
      await file.rename(backup);
      await log.log('Quarantined corrupted prefs to $backup');
    }
  } catch (e) {
    await log.log('Failed to quarantine corrupted prefs: $e');
  }
}
