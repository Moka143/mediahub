import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/secret_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the move of credentials out of `shared_preferences`.
///
/// The store itself is small; the migration is the part that can hurt. It
/// runs once, on a machine that already has the user's qBittorrent password
/// and TMDB tokens sitting in a plist or the registry, and it has to do two
/// things without fail: carry them across, and then actually remove them. A
/// migration that copies but does not scrub makes the whole change cosmetic;
/// one that scrubs but does not copy signs the user out and loses their
/// qBittorrent password.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> prefsWith(Map<String, Object> seed) async {
    SharedPreferences.setMockInitialValues(seed);
    return SharedPreferences.getInstance();
  }

  /// The shape an older build left behind: two credentials inside the
  /// settings blob, one under its own key.
  Map<String, Object> legacyStore({
    String? password = 'hunter2',
    String? readToken = 'eyJhbGciOiJIUzI1NiJ9.read',
    String? accessToken = 'eyJhbGciOiJIUzI1NiJ9.oauth',
    int port = 8080,
  }) {
    return {
      SecretStore.legacySettingsKey: jsonEncode({
        'host': 'localhost',
        'port': port,
        'username': 'admin',
        'password': ?password,
        'tmdb_api_key': ?readToken,
      }),
      SecretStore.legacyAccessTokenKey: ?accessToken,
    };
  }

  Map<String, dynamic> settingsBlob(SharedPreferences prefs) =>
      jsonDecode(prefs.getString(SecretStore.legacySettingsKey)!)
          as Map<String, dynamic>;

  group('migration', () {
    test('carries all three credentials across', () async {
      final prefs = await prefsWith(legacyStore());
      final store = await SecretStore.open(
        prefs,
        backend: InMemorySecretBackend(),
      );

      expect(store.read(Secret.qbittorrentPassword), 'hunter2');
      expect(store.read(Secret.tmdbReadToken), 'eyJhbGciOiJIUzI1NiJ9.read');
      expect(store.read(Secret.tmdbAccessToken), 'eyJhbGciOiJIUzI1NiJ9.oauth');
    });

    test('scrubs them from shared_preferences', () async {
      // The point of the exercise. Leaving them behind would mean the
      // credentials are now in two places instead of one better place.
      final prefs = await prefsWith(legacyStore());
      await SecretStore.open(prefs, backend: InMemorySecretBackend());

      expect(prefs.getString(SecretStore.legacyAccessTokenKey), isNull);
      expect(settingsBlob(prefs).containsKey('password'), isFalse);
      expect(settingsBlob(prefs).containsKey('tmdb_api_key'), isFalse);
    });

    test('leaves the non-secret settings alone', () async {
      // Rewriting the blob must not cost the user their port or save path.
      final prefs = await prefsWith(legacyStore(port: 9091));
      await SecretStore.open(prefs, backend: InMemorySecretBackend());

      final blob = settingsBlob(prefs);
      expect(blob['host'], 'localhost');
      expect(blob['port'], 9091);
      expect(blob['username'], 'admin');
    });

    test(
      'a value already in secure storage wins over the legacy one',
      () async {
        // Reached if a previous migration succeeded but the scrub did not —
        // the newer value must not be overwritten by the stale plaintext.
        final prefs = await prefsWith(legacyStore(password: 'stale'));
        final store = await SecretStore.open(
          prefs,
          backend: InMemorySecretBackend({
            Secret.qbittorrentPassword.key: 'current',
          }),
        );
        expect(store.read(Secret.qbittorrentPassword), 'current');
      },
    );

    test('is a no-op on a fresh install', () async {
      final prefs = await prefsWith({});
      final store = await SecretStore.open(
        prefs,
        backend: InMemorySecretBackend(),
      );
      for (final secret in Secret.values) {
        expect(store.read(secret), isNull, reason: secret.name);
      }
      expect(prefs.getString(SecretStore.legacySettingsKey), isNull);
    });

    test('survives a corrupt settings blob', () async {
      // prefs_recovery handles the general case, but this runs before the
      // settings notifier does — it must not take the app down with it.
      final prefs = await prefsWith({
        SecretStore.legacySettingsKey: 'not json at all',
        SecretStore.legacyAccessTokenKey: 'token',
      });
      final store = await SecretStore.open(
        prefs,
        backend: InMemorySecretBackend(),
      );
      expect(store.read(Secret.tmdbAccessToken), 'token');
      expect(store.read(Secret.qbittorrentPassword), isNull);
    });

    test('ignores empty credentials rather than storing blanks', () async {
      // A default-constructed AppSettings writes password: '' — adopting it
      // would mask a real value written later.
      final prefs = await prefsWith(
        legacyStore(password: '', readToken: '', accessToken: ''),
      );
      final store = await SecretStore.open(
        prefs,
        backend: InMemorySecretBackend(),
      );
      expect(store.read(Secret.qbittorrentPassword), isNull);
      expect(store.read(Secret.tmdbReadToken), isNull);
      expect(store.read(Secret.tmdbAccessToken), isNull);
    });

    test('runs clean a second time', () async {
      // Every launch calls open(); only the first has anything to do.
      final prefs = await prefsWith(legacyStore());
      final backend = InMemorySecretBackend();
      await SecretStore.open(prefs, backend: backend);
      final second = await SecretStore.open(prefs, backend: backend);

      expect(second.read(Secret.qbittorrentPassword), 'hunter2');
      expect(second.read(Secret.tmdbAccessToken), 'eyJhbGciOiJIUzI1NiJ9.oauth');
      expect(settingsBlob(prefs).containsKey('password'), isFalse);
    });
  });

  group('a backend that accepts a write but stores nothing', () {
    // The case an exception check cannot catch. Everything looks fine and
    // the credentials are gone — which is what happened the first time this
    // migration ran for real.
    test('keeps the plaintext rather than scrubbing it', () async {
      final prefs = await prefsWith(legacyStore());
      await SecretStore.open(prefs, backend: _SilentlyDiscardsBackend());

      expect(
        prefs.getString(SecretStore.legacyAccessTokenKey),
        'eyJhbGciOiJIUzI1NiJ9.oauth',
      );
      expect(settingsBlob(prefs)['password'], 'hunter2');
      expect(settingsBlob(prefs)['tmdb_api_key'], 'eyJhbGciOiJIUzI1NiJ9.read');
    });

    test('still serves the credentials for this session', () async {
      // The cache holds them even though the backend did not, so the user is
      // not signed out of a session that was working a moment ago.
      final prefs = await prefsWith(legacyStore());
      final store = await SecretStore.open(
        prefs,
        backend: _SilentlyDiscardsBackend(),
      );

      expect(store.read(Secret.qbittorrentPassword), 'hunter2');
      expect(store.read(Secret.tmdbAccessToken), 'eyJhbGciOiJIUzI1NiJ9.oauth');
    });

    test('a later launch with a working backend migrates properly', () async {
      final prefs = await prefsWith(legacyStore());
      await SecretStore.open(prefs, backend: _SilentlyDiscardsBackend());

      final backend = InMemorySecretBackend();
      final store = await SecretStore.open(prefs, backend: backend);

      expect(store.read(Secret.qbittorrentPassword), 'hunter2');
      expect(backend.values[Secret.qbittorrentPassword.key], 'hunter2');
      expect(prefs.getString(SecretStore.legacyAccessTokenKey), isNull);
      expect(settingsBlob(prefs).containsKey('password'), isFalse);
    });
  });

  group('a backend that reads back something else', () {
    test('treats a mismatch as a failed write', () async {
      final prefs = await prefsWith(legacyStore());
      await SecretStore.open(prefs, backend: _CorruptsOnWriteBackend());

      expect(settingsBlob(prefs)['password'], 'hunter2');
      expect(
        prefs.getString(SecretStore.legacyAccessTokenKey),
        'eyJhbGciOiJIUzI1NiJ9.oauth',
      );
    });
  });

  group('a backend that refuses to write', () {
    test('leaves the plaintext in prefs rather than destroying it', () async {
      // The bug a real macOS run found. Every Keychain write was failing with
      // errSecMissingEntitlement, `write` swallowed the error, and the
      // migration scrubbed both TMDB tokens anyway — so they existed in
      // neither place. Restoring needed a backup taken beforehand.
      final prefs = await prefsWith(legacyStore());
      final store = await SecretStore.open(
        prefs,
        backend: _WriteFailsBackend(),
      );

      // Nothing was persisted...
      expect(
        store.read(Secret.tmdbAccessToken),
        'eyJhbGciOiJIUzI1NiJ9.oauth',
        reason: 'the session still works from cache',
      );
      // ...so nothing may be removed.
      expect(
        prefs.getString(SecretStore.legacyAccessTokenKey),
        'eyJhbGciOiJIUzI1NiJ9.oauth',
      );
      expect(settingsBlob(prefs)['password'], 'hunter2');
      expect(settingsBlob(prefs)['tmdb_api_key'], 'eyJhbGciOiJIUzI1NiJ9.read');
    });

    test('a later launch with a working backend still migrates', () async {
      // The point of leaving it: the next run gets another chance.
      final prefs = await prefsWith(legacyStore());
      await SecretStore.open(prefs, backend: _WriteFailsBackend());

      final store = await SecretStore.open(
        prefs,
        backend: InMemorySecretBackend(),
      );
      expect(store.read(Secret.tmdbAccessToken), 'eyJhbGciOiJIUzI1NiJ9.oauth');
      expect(store.read(Secret.tmdbReadToken), 'eyJhbGciOiJIUzI1NiJ9.read');
      expect(prefs.getString(SecretStore.legacyAccessTokenKey), isNull);
      expect(settingsBlob(prefs).containsKey('tmdb_api_key'), isFalse);
    });

    test('one failing secret does not block the others', () async {
      // Only the read token fails here; the OAuth token must still move, and
      // only the read token's plaintext stays behind.
      final prefs = await prefsWith(legacyStore());
      final store = await SecretStore.open(
        prefs,
        backend: _SelectiveFailBackend(Secret.tmdbReadToken.key),
      );

      expect(prefs.getString(SecretStore.legacyAccessTokenKey), isNull);
      expect(settingsBlob(prefs).containsKey('password'), isFalse);
      expect(settingsBlob(prefs)['tmdb_api_key'], 'eyJhbGciOiJIUzI1NiJ9.read');
      expect(store.read(Secret.tmdbAccessToken), isNotNull);
    });

    test('write reports whether it reached the backend', () async {
      final prefs = await prefsWith({});
      final ok = await SecretStore.open(
        prefs,
        backend: InMemorySecretBackend(),
      );
      expect(await ok.write(Secret.tmdbReadToken, 'v'), isTrue);

      final bad = await SecretStore.open(prefs, backend: _WriteFailsBackend());
      expect(await bad.write(Secret.tmdbReadToken, 'v'), isFalse);
    });
  });

  group('read and write', () {
    test('a written secret is readable immediately and persists', () async {
      final prefs = await prefsWith({});
      final backend = InMemorySecretBackend();
      final store = await SecretStore.open(prefs, backend: backend);

      await store.write(Secret.qbittorrentPassword, 's3cret');
      expect(store.read(Secret.qbittorrentPassword), 's3cret');
      expect(
        backend.values,
        containsPair(Secret.qbittorrentPassword.key, 's3cret'),
      );

      final reopened = await SecretStore.open(prefs, backend: backend);
      expect(reopened.read(Secret.qbittorrentPassword), 's3cret');
    });

    test('writing null or empty clears the secret', () async {
      // How sign-out drops the OAuth token.
      final prefs = await prefsWith({});
      final backend = InMemorySecretBackend();
      final store = await SecretStore.open(prefs, backend: backend);

      await store.write(Secret.tmdbAccessToken, 'token');
      await store.write(Secret.tmdbAccessToken, null);
      expect(store.read(Secret.tmdbAccessToken), isNull);
      expect(backend.values, isNot(contains(Secret.tmdbAccessToken.key)));

      await store.write(Secret.tmdbAccessToken, 'token');
      await store.write(Secret.tmdbAccessToken, '');
      expect(store.read(Secret.tmdbAccessToken), isNull);
    });

    test('a failing backend still serves the session', () async {
      // A locked Keychain must not break the running app: the value is used
      // for this session, and only persistence is lost. See the migration
      // group for the other half — it must not delete anything either.
      final prefs = await prefsWith({});
      final store = await SecretStore.open(
        prefs,
        backend: _WriteFailsBackend(),
      );
      await store.write(Secret.qbittorrentPassword, 'transient');
      expect(store.read(Secret.qbittorrentPassword), 'transient');
    });

    test(
      'an unreadable backend degrades to memory instead of throwing',
      () async {
        // Missing libsecret, or a Keychain that will not open. Starting with
        // no credentials beats refusing to start, and beats falling back to
        // plaintext on disk.
        final prefs = await prefsWith(legacyStore());
        final store = await SecretStore.open(
          prefs,
          backend: _ReadFailsBackend(),
        );

        expect(store.read(Secret.qbittorrentPassword), isNull);
        // And the legacy blob is left intact, so a later launch with a working
        // backend can still migrate it.
        expect(settingsBlob(prefs)['password'], 'hunter2');
      },
    );

    test('the in-memory store keeps nothing between instances', () async {
      final store = SecretStore.inMemory();
      await store.write(Secret.tmdbReadToken, 'ephemeral');
      expect(store.read(Secret.tmdbReadToken), 'ephemeral');
      expect(SecretStore.inMemory().read(Secret.tmdbReadToken), isNull);
    });
  });
}

/// Writes fail for one named key only.
class _SelectiveFailBackend implements SecretBackend {
  _SelectiveFailBackend(this.failingKey);

  final String failingKey;
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == failingKey) throw StateError('refused');
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Accepts every write, throws nothing, and stores nothing.
///
/// The failure the migration cannot detect by watching for exceptions, and
/// the one that would repeat the original incident: `write` reports success,
/// the plaintext gets scrubbed, and the credential is nowhere.
class _SilentlyDiscardsBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}

/// Stores a value, but hands back a different one on read.
class _CorruptsOnWriteBackend implements SecretBackend {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async =>
      _values[key] = '$value-mangled';

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class _WriteFailsBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('keychain locked');

  @override
  Future<void> delete(String key) async => throw StateError('keychain locked');
}

class _ReadFailsBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async =>
      throw StateError('libsecret missing');

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}
}
