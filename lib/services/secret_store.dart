import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// The three values in this app that are worth protecting.
///
/// Everything else in settings is a preference — a port, a save path, a poll
/// interval — and belongs in `shared_preferences` where it is easy to inspect
/// and easy to reset. These three are credentials.
enum Secret {
  /// qBittorrent Web UI password. Grants full control of the torrent client,
  /// including its save paths, to anything that can read it.
  qbittorrentPassword('qbittorrent_password'),

  /// The user's TMDB v4 read access token.
  tmdbReadToken('tmdb_read_token'),

  /// The OAuth access token for the signed-in TMDB account. Acts on the
  /// user's behalf — rates, watchlists, favourites.
  tmdbAccessToken('tmdb_access_token');

  const Secret(this.key);

  /// Storage key. Stable: changing one silently signs the user out.
  final String key;
}

/// Where secrets are actually kept.
///
/// An interface rather than a direct `FlutterSecureStorage` call so tests get
/// an in-memory store instead of writing to the developer's real Keychain,
/// and so a platform without a working backend degrades in one place.
abstract class SecretBackend {
  /// One key at a time, deliberately — see [PlatformSecretBackend].
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain on macOS, DPAPI on Windows, libsecret on Linux.
class PlatformSecretBackend implements SecretBackend {
  const PlatformSecretBackend([
    this._storage = const FlutterSecureStorage(
      // The data-protection keychain — the plugin's default — requires the
      // app to be signed with a `keychain-access-groups` entitlement, and
      // this app ships ad-hoc signed with no team identifier, so every write
      // failed with errSecMissingEntitlement (-34018). The classic
      // file-based Keychain needs no entitlement for a non-sandboxed app and
      // is still the real Keychain: encrypted at rest, ACL'd per app.
      //
      // `accessibility` is deliberately not set alongside it.
      // `kSecAttrAccessible` only exists on the data-protection keychain, so
      // passing both makes every call fail with errSecParam (-50) instead.
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ),
  ]);

  final FlutterSecureStorage _storage;

  /// Reads are per-key rather than a single `readAll()`.
  ///
  /// The classic keychain rejects `kSecMatchLimitAll` together with
  /// `kSecReturnData` — a `readAll()` comes back errSecParam (-50) every
  /// time. There are three keys, so asking for each by name is both the
  /// working call and the narrower one: it never reads an entry this app
  /// did not write.
  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// A backend that keeps secrets for the life of the process and no longer.
///
/// The default in tests, and the fallback when the platform backend cannot be
/// reached. Falling back to plaintext on disk would defeat the point; losing
/// the credentials at exit is the safe failure.
class InMemorySecretBackend implements SecretBackend {
  InMemorySecretBackend([Map<String, String>? seed]) : _values = {...?seed};

  final Map<String, String> _values;

  /// The stored entries, for tests to assert against.
  Map<String, String> get values => Map.of(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Reads every secret once at startup and serves them synchronously after.
///
/// The synchronous read is the whole design constraint. `SettingsNotifier`
/// and `TmdbSessionNotifier` both `build()` synchronously off
/// `SharedPreferences`, and the secure-storage APIs are async-only. Loading
/// once in `main()` — which already awaits prefs — and overriding
/// [secretStoreProvider] keeps those notifiers synchronous, instead of
/// turning every settings read in the app into an `AsyncValue`.
///
/// Writes are async and write through to both the cache and the backend.
class SecretStore {
  SecretStore._(this._backend, this._cache);

  /// A store backed only by memory. The default for tests, so nothing in the
  /// suite can reach the developer's real Keychain.
  factory SecretStore.inMemory([Map<Secret, String>? seed]) {
    return SecretStore._(InMemorySecretBackend(), {
      for (final entry in (seed ?? {}).entries) entry.key: entry.value,
    });
  }

  final SecretBackend _backend;
  final Map<Secret, String> _cache;

  /// Load every secret, migrating any that are still sitting in prefs.
  ///
  /// Falls back to an in-memory store if the platform backend throws — a
  /// missing libsecret, a locked Keychain. The app then runs and the user
  /// re-enters credentials, which is better than either refusing to start or
  /// quietly writing them somewhere readable.
  static Future<SecretStore> open(
    SharedPreferences prefs, {
    SecretBackend backend = const PlatformSecretBackend(),
  }) async {
    final cache = <Secret, String>{};
    try {
      for (final secret in Secret.values) {
        final value = await backend.read(secret.key);
        if (value != null && value.isNotEmpty) cache[secret] = value;
      }
    } catch (e) {
      // Any failure disqualifies the whole backend: we cannot tell a missing
      // secret from an unreadable one, and migrating against a store we
      // cannot read would scrub plaintext we might not be able to replace.
      AppLog.e(
        '[SecretStore] secure storage unavailable ($e) — credentials will '
        'not persist this session',
      );
      return SecretStore._(InMemorySecretBackend(), {});
    }

    final store = SecretStore._(backend, cache);
    await store._migrateFromPrefs(prefs);
    return store;
  }

  String? read(Secret secret) => _cache[secret];

  /// Persist [value], or clear the secret when it is null or empty.
  ///
  /// Returns whether it actually reached the backend. The cache is updated
  /// either way, so the running session behaves correctly even when the
  /// Keychain refuses — but callers that are about to destroy their only
  /// other copy of the value must check this. [_migrateFromPrefs] is exactly
  /// that caller.
  Future<bool> write(Secret secret, String? value) async {
    try {
      if (value == null || value.isEmpty) {
        _cache.remove(secret);
        await _backend.delete(secret.key);
      } else {
        _cache[secret] = value;
        await _backend.write(secret.key, value);
      }
      return true;
    } catch (e) {
      AppLog.e('[SecretStore] failed to persist ${secret.key}: $e');
      return false;
    }
  }

  /// Adopt credentials written by an older build, then scrub them.
  ///
  /// Every install that predates this store has all three sitting in
  /// `shared_preferences` — a plist under `~/Library/Preferences` on macOS,
  /// the registry on Windows. Leaving them there after copying would make
  /// this change cosmetic, so each one is removed once it is safely stored.
  ///
  /// Two of them live inside the `app_settings` JSON blob rather than under
  /// their own keys, so that blob is rewritten without them.
  ///
  /// **A credential is only ever removed once it is confirmed stored.** The
  /// first run of this on a real machine scrubbed both TMDB tokens while
  /// every Keychain write was failing with errSecMissingEntitlement, because
  /// [write] swallowed the error — the tokens existed nowhere afterwards. A
  /// backend that refuses now leaves the plaintext in place so the next
  /// launch can retry.
  Future<void> _migrateFromPrefs(SharedPreferences prefs) async {
    var migrated = 0;

    /// Copy [legacy] into secure storage. Returns whether the plaintext is
    /// now safe to delete — true when it was stored, when the secret was
    /// already there, or when there was nothing to copy.
    Future<bool> adopt(Secret secret, String? legacy) async {
      if (legacy == null || legacy.isEmpty) return true;
      if (_cache.containsKey(secret)) return true; // secure storage wins
      final stored = await write(secret, legacy);
      if (stored) migrated++;
      return stored;
    }

    final tokenSafe = await adopt(
      Secret.tmdbAccessToken,
      prefs.getString(_legacyAccessTokenKey),
    );
    if (tokenSafe && prefs.containsKey(_legacyAccessTokenKey)) {
      await prefs.remove(_legacyAccessTokenKey);
    }

    final raw = prefs.getString(_legacySettingsKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final passwordSafe = await adopt(
          Secret.qbittorrentPassword,
          json['password'] as String?,
        );
        final readTokenSafe = await adopt(
          Secret.tmdbReadToken,
          json['tmdb_api_key'] as String?,
        );
        // Ternaries rather than `&&`, so the second removal is never skipped
        // by a short-circuit on the first.
        final removedPassword = passwordSafe
            ? json.remove('password') != null
            : false;
        final removedReadToken = readTokenSafe
            ? json.remove('tmdb_api_key') != null
            : false;
        if (removedPassword || removedReadToken) {
          await prefs.setString(_legacySettingsKey, jsonEncode(json));
        }
      } catch (e) {
        AppLog.w('[SecretStore] could not scrub legacy settings blob: $e');
      }
    }

    if (migrated > 0) {
      AppLog.i(
        '[SecretStore] moved $migrated credential(s) out of shared_preferences',
      );
    }
  }

  @visibleForTesting
  static const legacySettingsKey = _legacySettingsKey;

  @visibleForTesting
  static const legacyAccessTokenKey = _legacyAccessTokenKey;
}

/// Where the settings blob lives — must match `settings_provider.dart`.
const _legacySettingsKey = 'app_settings';

/// Where the TMDB OAuth token used to live — must match
/// `tmdb_account_provider.dart`.
const _legacyAccessTokenKey = 'tmdb_v4_access_token';
