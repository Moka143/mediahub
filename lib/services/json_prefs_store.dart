import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// One JSON value in `shared_preferences`, read so that damage costs as
/// little as possible and is never silently written over.
///
/// Seven notifiers persisted JSON blobs, and each handled a bad one
/// differently: favorites and the watchlist quarantined it, watch progress
/// and auto-download logged and fell back to empty, the event log fell back
/// silently. The fallback is the dangerous part. The very next save writes
/// the empty value over the only copy, so a single unreadable entry — one
/// row of a watch history — took the whole history with it.
///
/// What this does instead:
///
///  * **Per-entry decoding.** A list or map is decoded entry by entry; an
///    entry that fails is skipped, and the rest survive.
///  * **Quarantine before loss.** Whenever anything was skipped, or the whole
///    value was unreadable, the raw stored string is copied to
///    `<key>.corrupt` *before* the caller gets its (partial) result. The next
///    save then drops only what could not be read, and that is still on disk.
///  * **Versioning beside, not inside.** The schema version lives under
///    `<key>.version`, so the stored value keeps exactly the shape older
///    builds read — a downgrade does not turn a history into "unreadable".
///    A value written by a *newer* schema than this build knows is
///    quarantined before anything here overwrites it.
class JsonPrefsStore {
  JsonPrefsStore(this._prefs, this.key, {this.version = 1});

  final SharedPreferences _prefs;

  /// The prefs key holding the JSON value.
  final String key;

  /// The schema version this build writes. Values with no recorded version
  /// are version 1 — everything written before versions were recorded.
  final int version;

  /// Where an unreadable or partly-unreadable raw value is kept.
  String get corruptKey => '$key.corrupt';

  /// Where the schema version of the stored value is recorded.
  String get versionKey => '$key.version';

  /// The schema version of the stored value.
  int get storedVersion => _prefs.getInt(versionKey) ?? 1;

  /// The decoded JSON, or null when nothing is stored.
  ///
  /// A value that does not parse is quarantined and reads as null.
  Object? readJson() {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    if (storedVersion > version) {
      // A newer build wrote this. Reading it with today's decoder would
      // drop whatever it added, and the next save would make that final.
      quarantine('written by a newer schema (v$storedVersion > v$version)');
    }
    try {
      return jsonDecode(raw);
    } catch (e) {
      quarantine('not valid JSON ($e)');
      return null;
    }
  }

  /// The stored JSON list, decoded entry by entry with [decode].
  ///
  /// Entries [decode] throws on are skipped (and the raw value quarantined);
  /// a value that is not a list reads as empty (and is quarantined).
  List<T> readList<T>(T Function(Object? entry) decode) {
    final json = readJson();
    if (json == null) return <T>[];
    if (json is! List) {
      quarantine('expected a list, found ${json.runtimeType}');
      return <T>[];
    }
    final out = <T>[];
    var skipped = 0;
    for (final entry in json) {
      try {
        out.add(decode(entry));
      } catch (_) {
        skipped++;
      }
    }
    if (skipped > 0) {
      quarantine('$skipped of ${json.length} entries unreadable');
    }
    return out;
  }

  /// The stored JSON object, or null when absent or not an object (the
  /// latter quarantined). Decoding its fields is the caller's job — see
  /// [decodeEntries] for maps of entries.
  Map<String, dynamic>? readMap() {
    final json = readJson();
    if (json == null) return null;
    if (json is! Map<String, dynamic>) {
      quarantine('expected an object, found ${json.runtimeType}');
      return null;
    }
    return json;
  }

  /// Decode the entries of one JSON object field independently, skipping
  /// (and quarantining for) the ones that fail.
  ///
  /// [field] is only used in the log line.
  Map<K, V> decodeEntries<K, V>(
    Object? json,
    MapEntry<K, V> Function(String key, Object? value) decode, {
    required String field,
  }) {
    if (json == null) return <K, V>{};
    if (json is! Map) {
      quarantine('"$field" is not an object');
      return <K, V>{};
    }
    final out = <K, V>{};
    var skipped = 0;
    for (final entry in json.entries) {
      try {
        final decoded = decode(entry.key as String, entry.value);
        out[decoded.key] = decoded.value;
      } catch (_) {
        skipped++;
      }
    }
    if (skipped > 0) quarantine('$skipped "$field" entries unreadable');
    return out;
  }

  /// Copy the raw stored value aside, once per load, before a caller falls
  /// back to whatever could be read.
  ///
  /// Synchronous on purpose — callers run inside provider `build()`. The
  /// prefs write is in memory at once and reaches disk in the background.
  void quarantine(String reason) {
    final raw = _prefs.getString(key);
    AppLog.e('[Prefs] "$key" partly unreadable: $reason');
    if (raw == null || raw.isEmpty) return;
    if (_prefs.getString(corruptKey) == raw) return; // already kept
    AppLog.w('[Prefs] kept the raw "$key" value under "$corruptKey"');
    unawaited(_prefs.setString(corruptKey, raw));
  }

  /// Store [json], recording this build's schema version alongside it.
  Future<void> write(Object? json) async {
    await _prefs.setString(key, jsonEncode(json));
    if (version != 1 || _prefs.containsKey(versionKey)) {
      await _prefs.setInt(versionKey, version);
    }
  }

  /// Remove the stored value (and its version). The quarantine is kept.
  Future<void> remove() async {
    await _prefs.remove(key);
    await _prefs.remove(versionKey);
  }
}

/// Decode an enum persisted by index (how this app has always stored them)
/// or by name, rejecting anything out of range.
///
/// Throws [FormatException] rather than guessing: inside a
/// [JsonPrefsStore.readList] or [JsonPrefsStore.decodeEntries] that skips
/// the one entry and quarantines the raw value, where a bare
/// `values[index]` threw a `RangeError` that reset *every* entry. A missing
/// value (null) decodes to [fallback] — older rows predate the field.
T enumFromJson<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw == null) return fallback;
  if (raw is int) {
    if (raw >= 0 && raw < values.length) return values[raw];
    throw FormatException('No ${T.toString()} at index $raw');
  }
  if (raw is String) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
  }
  throw FormatException('Not a ${T.toString()}: $raw');
}
