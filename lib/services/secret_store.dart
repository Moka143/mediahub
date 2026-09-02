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
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keychain on macOS, DPAPI on Windows, libsecret on Linux.
class PlatformSecretBackend implements SecretBackend {
  const PlatformSecretBackend([
    this._storage = const FlutterSecureStorage(
      mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
    ),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

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

  @override
  Future<Map<String, String>> readAll() async => Map.of(_values);

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
    Map<String, String> stored;
    try {
      stored = await backend.readAll();
    } catch (e) {
      AppLog.e(
        '[SecretStore] secure storage unavailable ($e) — credentials will '
        'not persist this session',
      );
      return SecretStore._(InMemorySecretBackend(), {});
    }

    final cache = <Secret, String>{
      for (final secret in Secret.values)
        if (stored[secret.key] case final value? when value.isNotEmpty)
          secret: value,
    };
    final store = SecretStore._(backend, cache);
    await store._migrateFromPrefs(prefs);
    return store;
  }

  String? read(Secret secret) => _cache[secret];

  /// Persist [value], or clear the secret when it is null or empty.
  Future<void> write(Secret secret, String? value) async {
    try {
      if (value == null || value.isEmpty) {
        _cache.remove(secret);
        await _backend.delete(secret.key);
      } else {
        _cache[secret] = value;
        await _backend.write(secret.key, value);
      }
    } catch (e) {
      // The cache is already updated, so the current session behaves
      // correctly; only persistence is lost.
      AppLog.e('[SecretStore] failed to persist ${secret.key}: $e');
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
  Future<void> _migrateFromPrefs(SharedPreferences prefs) async {
    var migrated = 0;

    Future<void> adopt(Secret secret, String? legacy) async {
      if (legacy == null || legacy.isEmpty) return;
      if (_cache.containsKey(secret)) return; // secure storage already wins
      await write(secret, legacy);
      migrated++;
    }

    await adopt(Secret.tmdbAccessToken, prefs.getString(_legacyAccessTokenKey));
    if (prefs.containsKey(_legacyAccessTokenKey)) {
      await prefs.remove(_legacyAccessTokenKey);
    }

    final raw = prefs.getString(_legacySettingsKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        await adopt(Secret.qbittorrentPassword, json['password'] as String?);
        await adopt(Secret.tmdbReadToken, json['tmdb_api_key'] as String?);
        // Both removals must run: folding them into one `||` short-circuits
        // and leaves the second credential in the blob.
        final hadPassword = json.remove('password') != null;
        final hadReadToken = json.remove('tmdb_api_key') != null;
        if (hadPassword || hadReadToken) {
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
