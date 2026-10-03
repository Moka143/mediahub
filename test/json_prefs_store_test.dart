import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/json_prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one way a JSON blob in prefs is read: entry by entry, with whatever
/// cannot be read kept aside before anything writes over it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<JsonPrefsStore> storeWith(
    Object? raw, {
    int version = 1,
    int? storedVersion,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (raw != null) 'k': raw is String ? raw : jsonEncode(raw),
      'k.version': ?storedVersion,
    });
    return JsonPrefsStore(
      await SharedPreferences.getInstance(),
      'k',
      version: version,
    );
  }

  Future<String?> quarantined() async =>
      (await SharedPreferences.getInstance()).getString('k.corrupt');

  group('readList', () {
    test('skips an unreadable entry and keeps the rest', () async {
      final store = await storeWith([1, 'two', 3]);
      expect(store.readList((e) => e! as int), [1, 3]);
      expect(await quarantined(), '[1,"two",3]');
    });

    test('a clean read quarantines nothing', () async {
      final store = await storeWith([1, 2]);
      expect(store.readList((e) => e! as int), [1, 2]);
      expect(await quarantined(), isNull);
    });

    test('unparseable JSON reads as empty, and is kept', () async {
      final store = await storeWith('not json');
      expect(store.readList((e) => e), isEmpty);
      expect(await quarantined(), 'not json');
    });

    test('the wrong shape reads as empty, and is kept', () async {
      final store = await storeWith({'a': 1});
      expect(store.readList((e) => e), isEmpty);
      expect(await quarantined(), isNotNull);
    });

    test('nothing stored is simply empty', () async {
      final store = await storeWith(null);
      expect(store.readList((e) => e), isEmpty);
      expect(await quarantined(), isNull);
    });
  });

  group('decodeEntries', () {
    test('decodes each entry of an object on its own', () async {
      final store = await storeWith(null);
      final decoded = store.decodeEntries<int, String>(
        {'1': 'a', 'x': 'b', '3': 'c'},
        (k, v) => MapEntry(int.parse(k), v! as String),
        field: 'names',
      );
      expect(decoded, {1: 'a', 3: 'c'});
    });
  });

  group('versioning', () {
    test('is recorded beside the value, which keeps its old shape', () async {
      final store = await storeWith(null, version: 2);
      await store.write([1, 2]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('k'), '[1,2]');
      expect(prefs.getInt('k.version'), 2);
    });

    test('a value from a newer schema is kept before it is read', () async {
      final store = await storeWith([1], storedVersion: 3, version: 2);
      expect(store.storedVersion, 3);
      expect(store.readList((e) => e! as int), [1]);
      expect(await quarantined(), '[1]');
    });
  });

  group('enumFromJson', () {
    test('reads an index, a name, or nothing', () {
      expect(enumFromJson(_Color.values, 1, _Color.red), _Color.green);
      expect(enumFromJson(_Color.values, 'blue', _Color.red), _Color.blue);
      expect(enumFromJson(_Color.values, null, _Color.red), _Color.red);
    });

    test('rejects what this build does not know', () {
      expect(
        () => enumFromJson(_Color.values, 7, _Color.red),
        throwsFormatException,
      );
      expect(
        () => enumFromJson(_Color.values, 'mauve', _Color.red),
        throwsFormatException,
      );
    });
  });
}

enum _Color { red, green, blue }
