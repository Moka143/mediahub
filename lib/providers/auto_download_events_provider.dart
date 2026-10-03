import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auto_download_event.dart';
import '../services/app_logger.dart';
import '../services/json_prefs_store.dart';
import 'settings_provider.dart';

const _eventsKey = 'auto_download_events';
const _maxEvents = 50;

/// The auto-download activity log, newest first.
final autoDownloadEventsProvider =
    NotifierProvider<AutoDownloadEventsNotifier, List<AutoDownloadEvent>>(
      AutoDownloadEventsNotifier.new,
    );

class AutoDownloadEventsNotifier extends Notifier<List<AutoDownloadEvent>> {
  late JsonPrefsStore _store;

  @override
  List<AutoDownloadEvent> build() {
    _store = JsonPrefsStore(ref.watch(sharedPreferencesProvider), _eventsKey);
    // Event by event: one this build cannot read (a newer event type) used
    // to silently empty the whole log.
    return _store.readList(
      (e) => AutoDownloadEvent.fromJson(e! as Map<String, dynamic>),
    );
  }

  Future<void> _saveEvents() async {
    try {
      await _store.write([for (final e in state) e.toJson()]);
    } catch (e) {
      // Non-critical: the log is a convenience, the downloads are not.
      AppLog.w('[AutoDownload] could not save the activity log: $e');
    }
  }

  /// Add a new event, prepend to list, cap at max
  Future<void> addEvent(AutoDownloadEvent event) async {
    state = [event, ...state].take(_maxEvents).toList();
    await _saveEvents();
  }

  /// Empty the log — for a "Clear" action next to it.
  Future<void> clearEvents() async {
    state = [];
    await _saveEvents();
  }
}
