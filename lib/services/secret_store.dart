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
  SecretStore._(this._backend, this._cache, [this._prefs]);

  /// A store backed only by memory. The default for tests, so nothing in the
  /// suite can reach the developer's real Keychain.
  factory SecretStore.inMemory([Map<Secret, String>? seed]) {
    return SecretStore._(InMemorySecretBackend(), {
      for (final entry in (seed ?? {}).entries) entry.key: entry.value,
    });
  }

  final SecretBackend _backend;
  final Map<Secret, String> _cache;

  /// The prefs the legacy plaintext lives in, when this store was [open]ed
  /// against them. Lets a sign-out remove a legacy copy that a
  /// failed migration had to leave behind.
  final SharedPreferences? _prefs;

  /// Credentials still sitting as plaintext in the `app_settings` blob
  /// because moving them into secure storage could not be confirmed — see
  /// [pendingLegacySettingsFields].
  final Map<Secret, String> _pendingLegacy = {};

  /// The blob field each settings-borne secret was stored under by older
  /// builds — and still is, while its migration is pending.
  static const Map<Secret, String> _legacySettingsFields = {
    Secret.qbittorrentPassword: 'password',
    Secret.tmdbReadToken: 'tmdb_api_key',
  };

  /// Plaintext credentials an older build left in the `app_settings` blob
  /// that could not be moved into secure storage — the Keychain refused, or
  /// could not be read at all this session. Keyed by their field name in
  /// that blob (`password`, `tmdb_api_key`).
  ///
  /// **Whoever rewrites the settings blob must write these back into it.**
  /// They are deliberately left there so the next launch can retry the
  /// migration — they are the only durable copy — and `AppSettings.toJson`
  /// omits both fields by design. A settings save that does not merge them
  /// deletes the credential everywhere: upgrade, deny the Keychain prompt,
  /// toggle any setting, and the next launch had no password and no token.
  ///
  /// An entry disappears once its value is safely stored: the migration
  /// succeeded on a later launch, or the user saved a new value that reached
  /// secure storage, or cleared it.
  Map<String, String> get pendingLegacySettingsFields => {
    for (final entry in _pendingLegacy.entries)
      _legacySettingsFields[entry.key]!: entry.value,
  };

  /// The single backend entry every secret lives in.
  ///
  /// One entry rather than one per secret, because macOS prompts for Keychain
  /// access **per item**: three items meant three "MediaHub wants to use your
  /// confidential information" dialogs at every launch, and the user had to
  /// answer each. One item is one prompt.
  ///
  /// (The other half of that annoyance is the code signature — "Always Allow"
  /// binds to it, and an ad-hoc signature changes on every rebuild, so the
  /// permission never sticks for a development build. That needs a stable
  /// signing identity and is not fixable here.)
  @visibleForTesting
  static const bundleKey = 'mediahub_secrets';

  /// Encode the cache as the bundle's stored form.
  ///
  /// Keyed by [Secret.key] — the same stable strings the per-secret entries
  /// used — so a secret added later reads back as absent from an older
  /// bundle rather than corrupting it.
  static String encodeBundle(Map<Secret, String> secrets) => jsonEncode({
    for (final entry in secrets.entries) entry.key.key: entry.value,
  });

  /// Decode a stored bundle. Returns null when it is not usable, which the
  /// caller must treat as "fall back to the per-secret entries" rather than
  /// as "there are no secrets" — the difference is whether the user has to
  /// sign in again.
  static Map<Secret, String>? decodeBundle(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final secret in Secret.values)
          if (json[secret.key] case final String v when v.isNotEmpty) secret: v,
      };
    } catch (e) {
      AppLog.e('[SecretStore] secret bundle is unreadable ($e)');
      return null;
    }
  }

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
    var fromPerSecretEntries = false;
    try {
      // One read, one Keychain prompt. This is the path every launch after
      // the first takes.
      final bundled = decodeBundle(await backend.read(bundleKey));
      if (bundled != null) {
        cache.addAll(bundled);
      } else {
        // No bundle yet, or an unreadable one: fall back to the layout older
        // builds wrote, one entry per secret. Costs one more round of prompts
        // on this launch only — [_consolidateSecrets] collapses it afterwards.
        for (final secret in Secret.values) {
          final value = await backend.read(secret.key);
          if (value != null && value.isNotEmpty) {
            cache[secret] = value;
            fromPerSecretEntries = true;
          }
        }
      }
    } catch (e) {
      // Any failure disqualifies the whole backend: we cannot tell a missing
      // secret from an unreadable one, and migrating against a store we
      // cannot read would scrub plaintext we might not be able to replace.
      AppLog.e(
        '[SecretStore] secure storage unavailable ($e) — credentials will '
        'not persist this session',
      );
      // Nothing was migrated, so any plaintext in the settings blob is still
      // the only copy — and has to survive this session's settings saves.
      return SecretStore._(InMemorySecretBackend(), {}, prefs)
        .._pendingLegacy.addAll(_legacyBlobSecrets(prefs));
    }

    final store = SecretStore._(backend, cache, prefs);
    await store._migrateFromPrefs(prefs);
    if (fromPerSecretEntries) await store._consolidateSecrets();
    return store;
  }

  /// Collapse per-secret entries written by an older build into the bundle.
  ///
  /// The old entries are removed **only** once the bundle has been written
  /// *and read back*, for the same reason [_migrateFromPrefs] verifies before
  /// scrubbing: a backend that accepts a write and stores nothing would
  /// otherwise take every credential with it. If anything here fails the old
  /// entries stay exactly where they are and the next launch tries again —
  /// the cost of failing is an extra prompt, not a lost login.
  Future<void> _consolidateSecrets() async {
    if (_cache.isEmpty) return;

    final bundle = encodeBundle(_cache);
    try {
      await _backend.write(bundleKey, bundle);
      if (await _backend.read(bundleKey) != bundle) {
        AppLog.e(
          '[SecretStore] bundle did not read back — leaving the per-secret '
          'entries in place',
        );
        return;
      }
    } catch (e) {
      AppLog.e('[SecretStore] could not write the secret bundle ($e)');
      return;
    }

    // Only the entries we actually read. Deleting one that was never there
    // is not free: the classic Keychain answers errSecMissingEntitlement for
    // a missing item, which would log an alarming line about a credential
    // that never existed.
    for (final secret in _cache.keys) {
      try {
        await _backend.delete(secret.key);
      } catch (e) {
        // A leftover entry is harmless: `open` prefers the bundle, so it is
        // never read again. Worth a line, not worth failing over.
        AppLog.w('[SecretStore] could not remove old ${secret.key} entry: $e');
      }
    }
    AppLog.i(
      '[SecretStore] consolidated ${_cache.length} secrets into one entry',
    );
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
    final clearing = value == null || value.isEmpty;
    if (clearing) {
      _cache.remove(secret);
      // Clearing is a decision about every copy. A legacy plaintext one left
      // behind would be adopted again at the next launch — signing the user
      // back in to an account they just signed out of.
      _pendingLegacy.remove(secret);
      await _forgetLegacyCopy(secret);
    } else {
      _cache[secret] = value;
    }

    try {
      // Every secret shares one entry, so any change rewrites all of them.
      // Clearing the last one removes the entry rather than leaving `{}`
      // behind, so an uninstall-reinstall starts genuinely empty.
      if (_cache.isEmpty) {
        await _backend.delete(bundleKey);
      } else {
        await _backend.write(bundleKey, encodeBundle(_cache));
      }
      // A new value is safely stored, so the old plaintext no longer needs
      // carrying through settings saves.
      if (!clearing) _pendingLegacy.remove(secret);
      return true;
    } catch (e) {
      AppLog.e('[SecretStore] failed to persist ${secret.key}: $e');
      return false;
    }
  }

  /// Remove [secret]'s legacy plaintext from prefs, when this store holds
  /// them. Only the OAuth token has a key of its own; the two that live in
  /// the settings blob go when the blob is next saved without them, which
  /// [pendingLegacySettingsFields] no longer asks for.
  Future<void> _forgetLegacyCopy(Secret secret) async {
    final prefs = _prefs;
    if (prefs == null || secret != Secret.tmdbAccessToken) return;
    if (prefs.containsKey(_legacyAccessTokenKey)) {
      await prefs.remove(_legacyAccessTokenKey);
    }
  }

  /// The settings-borne secrets still in the legacy `app_settings` blob.
  static Map<Secret, String> _legacyBlobSecrets(SharedPreferences prefs) {
    final raw = prefs.getString(_legacySettingsKey);
    if (raw == null) return const {};
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return {
        for (final entry in _legacySettingsFields.entries)
          if (json[entry.value] case final String v when v.isNotEmpty)
            entry.key: v,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Confirm [value] can actually be read back out of the backend.
  ///
  /// [write] reports success when the backend did not *throw*, which is not
  /// the same thing as the value being there. Everywhere else that
  /// distinction is harmless — a failed settings save leaves the value on
  /// screen for the user to try again. In [_migrateFromPrefs] it is the
  /// difference between a credential and no credential anywhere, because the
  /// caller is about to delete its only other copy.
  ///
  /// Both backends that exist today do throw on failure, so this is belt and
  /// braces rather than a fix for a live bug. It is here because the last
  /// incident in this file was exactly this shape: the code trusted a
  /// success signal it had not verified, scrubbed the plaintext, and both
  /// TMDB tokens were gone. Verifying costs three reads on a one-time
  /// migration and makes that failure structurally impossible instead of
  /// merely unlikely.
  ///
  /// Reads through [_backend] deliberately, not [read] — the cache was
  /// populated by the write we are trying to check, so asking it would only
  /// confirm our own optimism.
  Future<bool> _readsBackAs(Secret secret, String value) async {
    try {
      if (decodeBundle(await _backend.read(bundleKey))?[secret] == value) {
        return true;
      }
      AppLog.e(
        '[SecretStore] ${secret.key} was written without error but did not '
        'read back — leaving the plaintext copy in place',
      );
    } catch (e) {
      AppLog.e(
        '[SecretStore] could not verify ${secret.key} after writing it ($e) '
        '— leaving the plaintext copy in place',
      );
    }
    return false;
  }

  /// Adopt credentials written by an older build, then scrub them.
  ///
  /// Every install that predates this store has all three sitting in
  /// `shared_preferences` — a plist under `~/Library/Preferences` on macOS,
  /// and `shared_preferences.json` in the roaming app-support directory on
  /// Windows (not the registry: `shared_preferences_windows` has been
  /// file-backed for years). Leaving them there after copying would make this
  /// change cosmetic, so each one is removed once it is safely stored.
  ///
  /// Two of them live inside the `app_settings` JSON blob rather than under
  /// their own keys, so that blob is rewritten without them.
  ///
  /// **A credential is only ever removed once it is confirmed stored** —
  /// confirmed by reading it back, not by the write returning without an
  /// error. The first run of this on a real machine scrubbed both TMDB
  /// tokens while every Keychain write was failing with
  /// errSecMissingEntitlement, because [write] swallowed the error — the
  /// tokens existed nowhere afterwards. A backend that refuses, or that
  /// quietly stores nothing, now leaves the plaintext in place so the next
  /// launch can retry. See [_readsBackAs].
  Future<void> _migrateFromPrefs(SharedPreferences prefs) async {
    var migrated = 0;

    /// Copy [legacy] into secure storage. Returns whether the plaintext is
    /// now safe to delete — true when it was stored *and read back*, when
    /// the secret was already there, or when there was nothing to copy.
    Future<bool> adopt(Secret secret, String? legacy) async {
      if (legacy == null || legacy.isEmpty) return true;
      if (_cache.containsKey(secret)) return true; // secure storage wins
      if (!await write(secret, legacy)) return false;
      if (!await _readsBackAs(secret, legacy)) return false;
      migrated++;
      return true;
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
        // Whatever is still in the blob now is there on purpose, as the only
        // durable copy. Settings saves must carry it — see
        // [pendingLegacySettingsFields].
        _pendingLegacy
          ..remove(Secret.qbittorrentPassword)
          ..remove(Secret.tmdbReadToken)
          ..addAll(_legacyBlobSecrets(prefs));
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
