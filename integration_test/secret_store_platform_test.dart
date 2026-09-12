// Exercises SecretStore against the *real* platform backend.
//
// `test/secret_store_test.dart` covers the migration logic with fake
// backends, which is the right place for it — but the Keychain defect that
// destroyed both TMDB tokens was invisible to those tests by construction:
// the logic was correct and the platform refused the write. Only a real
// backend on a real machine catches that class of failure, so that is what
// this file uses.
//
//   flutter test integration_test/secret_store_platform_test.dart -d windows
//
// Prefs are mocked — nothing here touches the real settings file — but the
// secret backend is genuinely the platform one: DPAPI on Windows, Keychain
// on macOS, libsecret on Linux.
//
// Every key is namespaced (see [_NamespacedBackend]), so the suite reads and
// writes real OS-encrypted entries without ever naming a key a real install
// uses. Running it cannot sign a developer out of their own app, even if it
// crashes half way through — which a snapshot-and-restore approach could
// not promise.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mediahub/services/secret_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const backend = _NamespacedBackend(PlatformSecretBackend());

  const probe = 'probe';
  const absent = 'definitely_absent';

  group('platform backend', () {
    tearDown(() => backend.delete(probe));

    testWidgets('writes and reads a value back', (_) async {
      await backend.write(probe, 'hunter2');
      expect(await backend.read(probe), 'hunter2');
    });

    testWidgets('a written value outlives the instance that wrote it', (
      _,
    ) async {
      await backend.write(probe, 'persisted');
      // A separate instance re-reads through the OS rather than any
      // in-process cache — this is what "it persisted" actually means.
      const fresh = _NamespacedBackend(PlatformSecretBackend());
      expect(await fresh.read(probe), 'persisted');
    });

    testWidgets('reads a missing key as null rather than throwing', (_) async {
      expect(await backend.read(absent), isNull);
    });

    testWidgets('delete removes the value', (_) async {
      await backend.write(probe, 'transient');
      await backend.delete(probe);
      expect(await backend.read(probe), isNull);
    });

    testWidgets('deleting an absent key is a no-op, not an error', (_) async {
      await backend.delete(absent);
    });

    testWidgets('overwrites rather than appending', (_) async {
      await backend.write(probe, 'first');
      await backend.write(probe, 'second');
      expect(await backend.read(probe), 'second');
    });

    testWidgets('the plaintext scan can detect plaintext', (_) async {
      // Guards the test below, which asserts an *absence*. If the scanner
      // cannot find a value that is definitely in the clear, then its
      // silence proves nothing and the encryption test is decorative.
      const canary = 'canary-scan-selftest';
      final dir = await getApplicationSupportDirectory();
      final decoy = File(p.join(dir.path, '__scan_selftest.txt'));
      await decoy.writeAsString('prefix $canary suffix');
      addTearDown(() async {
        if (decoy.existsSync()) await decoy.delete();
      });

      final scan = await _scanForPlaintext(dir, canary);
      expect(
        scan.offenders,
        contains(p.basename(decoy.path)),
        reason: 'the scanner missed a value written in the clear',
      );
    });

    testWidgets('stores the value encrypted, not as plaintext on disk', (
      _,
    ) async {
      const canary = 'canary-pl41nt3xt-must-not-appear';
      await backend.write(probe, canary);

      // Non-vacuity: if the write never landed there would be nothing to
      // find, and an empty result would look like success.
      expect(
        await backend.read(probe),
        canary,
        reason: 'nothing was stored, so the scan below would prove nothing',
      );

      final dir = await getApplicationSupportDirectory();
      final scan = await _scanForPlaintext(dir, canary);

      // Non-vacuity again: the file the credential lives in must actually
      // have been read, not skipped because it was locked or missing.
      expect(
        scan.scanned,
        contains(_windowsStoreFileName),
        reason:
            'never read $_windowsStoreFileName '
            '(unreadable: ${scan.unreadable.join(", ")})',
      );

      expect(
        scan.offenders,
        isEmpty,
        reason:
            'credential found in plaintext in: '
            '${scan.offenders.join(", ")}',
      );
      // Only meaningful where the backing store is a file in this directory.
      // macOS keeps secrets in the Keychain and Linux in libsecret, so there
      // this would pass without having checked anything.
    }, skip: !Platform.isWindows);
  });

  group('SecretStore migration on the real backend', () {
    // Safe to wipe: these are the namespaced copies, not the real install's.
    Future<void> clear() async {
      await backend.delete(SecretStore.bundleKey);
      // The per-secret entries an older build wrote, in case a previous run
      // of this suite left any behind.
      for (final secret in Secret.values) {
        await backend.delete(secret.key);
      }
    }

    /// What is actually in the platform store, decoded from the one entry
    /// every secret now shares.
    Future<Map<Secret, String>?> stored() async =>
        SecretStore.decodeBundle(await backend.read(SecretStore.bundleKey));

    setUp(clear);
    tearDownAll(clear);

    Future<SharedPreferences> legacyPrefs() async {
      SharedPreferences.setMockInitialValues({
        SecretStore.legacyAccessTokenKey: 'oauth-token',
        SecretStore.legacySettingsKey: jsonEncode({
          'host': 'localhost',
          'port': 8080,
          'username': 'admin',
          'password': 'qbt-password',
          'tmdb_api_key': 'read-token',
        }),
      });
      return SharedPreferences.getInstance();
    }

    testWidgets('moves all three credentials into the platform store', (
      _,
    ) async {
      final prefs = await legacyPrefs();
      final store = await SecretStore.open(prefs, backend: backend);

      expect(store.read(Secret.qbittorrentPassword), 'qbt-password');
      expect(store.read(Secret.tmdbReadToken), 'read-token');
      expect(store.read(Secret.tmdbAccessToken), 'oauth-token');

      // Straight from the backend, not the store's cache: this is the
      // assertion the Keychain defect would have failed.
      expect(await stored(), {
        Secret.qbittorrentPassword: 'qbt-password',
        Secret.tmdbReadToken: 'read-token',
        Secret.tmdbAccessToken: 'oauth-token',
      });
    });

    testWidgets('scrubs the plaintext only once the write has landed', (
      _,
    ) async {
      final prefs = await legacyPrefs();
      await SecretStore.open(prefs, backend: backend);

      // Assert the pairing, not just the scrub. Checking only that the
      // plaintext is gone would pass just as happily in the case this whole
      // file exists to rule out: prefs emptied, nothing stored anywhere.
      final landed = await stored();
      for (final secret in Secret.values) {
        expect(
          landed?[secret],
          isNotNull,
          reason:
              '${secret.key} was dropped from prefs below without ever '
              'reaching the platform store',
        );
      }

      expect(prefs.getString(SecretStore.legacyAccessTokenKey), isNull);
      final blob =
          jsonDecode(prefs.getString(SecretStore.legacySettingsKey)!)
              as Map<String, dynamic>;
      expect(blob.containsKey('password'), isFalse);
      expect(blob.containsKey('tmdb_api_key'), isFalse);
      // Non-secrets are untouched.
      expect(blob['host'], 'localhost');
      expect(blob['port'], 8080);
      expect(blob['username'], 'admin');
    });

    testWidgets('the migrated credentials survive a fresh open', (_) async {
      final prefs = await legacyPrefs();
      await SecretStore.open(prefs, backend: backend);

      // Nothing is left in prefs to migrate, so if the reopened store still
      // has the credentials they genuinely came back out of the OS store.
      final reopened = await SecretStore.open(prefs, backend: backend);
      expect(reopened.read(Secret.qbittorrentPassword), 'qbt-password');
      expect(reopened.read(Secret.tmdbReadToken), 'read-token');
      expect(reopened.read(Secret.tmdbAccessToken), 'oauth-token');
    });

    testWidgets('write reports success against the real backend', (_) async {
      final prefs = await legacyPrefs();
      final store = await SecretStore.open(prefs, backend: backend);

      expect(await store.write(Secret.tmdbReadToken, 'rotated'), isTrue);
      expect((await stored())?[Secret.tmdbReadToken], 'rotated');

      expect(await store.write(Secret.tmdbReadToken, null), isTrue);
      expect((await stored())?[Secret.tmdbReadToken], isNull);
    });
  });
}

/// Sends every read and write to the real platform backend, under a key
/// prefix no real install uses.
///
/// This suite has to exercise genuine OS-encrypted storage — that is the
/// whole point of it — but the credential keys it drives are the same three
/// a developer's own install stores. Namespacing means the suite can delete
/// and overwrite freely without a crash mid-run costing anyone their
/// Keychain entries.
class _NamespacedBackend implements SecretBackend {
  const _NamespacedBackend(this._inner);

  final SecretBackend _inner;

  static const _prefix = '__mediahub_integration_test__';

  String _scoped(String key) => '$_prefix$key';

  @override
  Future<String?> read(String key) => _inner.read(_scoped(key));

  @override
  Future<void> write(String key, String value) =>
      _inner.write(_scoped(key), value);

  @override
  Future<void> delete(String key) => _inner.delete(_scoped(key));
}

/// The file `flutter_secure_storage_windows` keeps its DPAPI-encrypted JSON
/// in, inside the application support directory.
const _windowsStoreFileName = 'flutter_secure_storage.dat';

/// What [_scanForPlaintext] saw.
///
/// [scanned] and [unreadable] exist so a caller can tell "the value is not on
/// disk in the clear" apart from "nothing got looked at" — an empty
/// [offenders] means nothing without them.
class _ScanResult {
  const _ScanResult(this.offenders, this.scanned, this.unreadable);

  /// Files whose bytes contained the value.
  final List<String> offenders;

  /// Files actually opened and searched.
  final List<String> scanned;

  /// Files that could not be read, e.g. held open by another process.
  final List<String> unreadable;
}

/// Search every file under [dir] for [value] in UTF-8 or UTF-16LE.
///
/// Both encodings, because a Windows API in the chain could have written
/// either and finding only one of them would be a false all-clear.
Future<_ScanResult> _scanForPlaintext(Directory dir, String value) async {
  final utf8Needle = utf8.encode(value);
  final utf16Needle = <int>[
    for (final unit in value.codeUnits) ...[unit & 0xff, unit >> 8],
  ];

  final offenders = <String>[];
  final scanned = <String>[];
  final unreadable = <String>[];

  await for (final entity in dir.list(recursive: true)) {
    if (entity is! File) continue;
    final name = p.relative(entity.path, from: dir.path);
    Uint8List bytes;
    try {
      bytes = await entity.readAsBytes();
    } on FileSystemException {
      unreadable.add(name);
      continue;
    }
    scanned.add(name);
    if (_contains(bytes, utf8Needle) || _contains(bytes, utf16Needle)) {
      offenders.add(name);
    }
  }

  return _ScanResult(offenders, scanned, unreadable);
}

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
