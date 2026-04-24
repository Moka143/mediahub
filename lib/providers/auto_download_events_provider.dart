import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/auto_download_event.dart';
import 'settings_provider.dart';

const _eventsKey = 'auto_download_events';
const _maxEvents = 50;

/// Provider for auto-download activity events
final autoDownloadEventsProvider =
    NotifierProvider<AutoDownloadEventsNotifier, List<AutoDownloadEvent>>(
      AutoDownloadEventsNotifier.new,
    );

class AutoDownloadEventsNotifier extends Notifier<List<AutoDownloadEvent>> {
  @override
  List<AutoDownloadEvent> build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return _loadEvents(prefs);
  }

  List<AutoDownloadEvent> _loadEvents(SharedPreferences prefs) {
    try {
      final jsonString = prefs.getString(_eventsKey);
      if (jsonString == null) return [];
      final list = jsonDecode(jsonString) as List;
      return list
          .map((e) => AutoDownloadEvent.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> _saveEvents() async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final json = state.map((e) => e.toJson()).toList();
      await prefs.setString(_eventsKey, jsonEncode(json));
    } catch (e) {
      // Silently fail — events are non-critical
    }
  }

  /// Add a new event, prepend to list, cap at max
  Future<void> addEvent(AutoDownloadEvent event) async {
    state = [event, ...state].take(_maxEvents).toList();
    await _saveEvents();
  }

  /// Clear all events
  Future<void> clearEvents() async {
    state = [];
    await _saveEvents();
  }
}

/// Last 10 events for the status card
final recentAutoDownloadEventsProvider = Provider<List<AutoDownloadEvent>>((
  ref,
) {
  final events = ref.watch(autoDownloadEventsProvider);
  return events.take(10).toList();
});
