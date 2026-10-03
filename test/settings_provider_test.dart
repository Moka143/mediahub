import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/services/secret_store.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Keychain that cannot be read — denied prompt, locked keychain.
class _UnreadableBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => throw StateError('locked');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('locked');

  @override
  Future<void> delete(String key) async => throw StateError('locked');
}

Future<ProviderContainer> _container({
  Map<String, Object> prefs = const {},
  SecretStore? secrets,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sharedPreferences = await SharedPreferences.getInstance();
  final container = ProviderContainer.test(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      secretStoreProvider.overrideWithValue(secrets ?? SecretStore.inMemory()),
    ],
  );
  return container;
}

void main() {
  group('Transfers filter and sort', () {
    test('survive an unrelated settings change', () async {
      // They used to watch the whole settings object, so changing a poll
      // interval — or anything — reset the user's filter and sort.
      final container = await _container();
      container.read(currentFilterProvider.notifier).set(TorrentFilter.seeding);
      container.read(currentSortProvider.notifier).set(TorrentSort.name);
      container.read(sortAscendingProvider.notifier).set(true);

      await container.read(settingsProvider.notifier).setUpdateInterval(9);
      await container
          .read(settingsProvider.notifier)
          .setTmdbApiKey('eyJ.new.token');

      expect(container.read(currentFilterProvider), TorrentFilter.seeding);
      expect(container.read(currentSortProvider), TorrentSort.name);
      expect(container.read(sortAscendingProvider), isTrue);
    });
  });

  group('resetToDefaults', () {
    test('puts a built-in user back on the built-in engine', () async {
      final container = await _container(
        prefs: {
          'flutter.app_settings': jsonEncode({
            'engine_kind': TorrentEngineKind.builtin.index,
            'update_interval_seconds': 9,
          }),
        },
      );
      expect(
        container.read(settingsProvider).engineKind,
        TorrentEngineKind.builtin,
      );

      await container.read(settingsProvider.notifier).resetToDefaults();

      final settings = container.read(settingsProvider);
      expect(
        settings.engineKind,
        TorrentEngineKind.builtin,
        reason: 'AppSettings() would have meant qBittorrent',
      );
      expect(settings.updateIntervalSeconds, 2);
    });

    test('clears the stored credentials too', () async {
      // Resetting only the state blanked them for the session; the next
      // launch read them straight back out of the Keychain.
      final secrets = SecretStore.inMemory({
        Secret.qbittorrentPassword: 'hunter2',
        Secret.tmdbReadToken: 'eyJ.token',
        Secret.tmdbAccessToken: 'account-session',
      });
      final container = await _container(secrets: secrets);
      expect(container.read(settingsProvider).password, 'hunter2');

      await container.read(settingsProvider.notifier).resetToDefaults();

      expect(secrets.read(Secret.qbittorrentPassword), isNull);
      expect(secrets.read(Secret.tmdbReadToken), isNull);
      expect(container.read(settingsProvider).password, isEmpty);
      expect(
        secrets.read(Secret.tmdbAccessToken),
        'account-session',
        reason: 'the TMDB sign-in is not a setting; it has its own Sign out',
      );
    });
  });

  group('saving', () {
    test('carries a credential the Keychain could not take', () async {
      // Upgrade, deny the Keychain prompt, change any setting: the plaintext
      // left in the settings blob is the only copy, and a save that dropped
      // it lost the password everywhere.
      SharedPreferences.setMockInitialValues({
        'flutter.app_settings': jsonEncode({
          'host': 'localhost',
          'password': 'legacy-pass',
        }),
      });
      final prefs = await SharedPreferences.getInstance();
      final secrets = await SecretStore.open(
        prefs,
        backend: _UnreadableBackend(),
      );
      final container = ProviderContainer.test(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          secretStoreProvider.overrideWithValue(secrets),
        ],
      );

      await container.read(settingsProvider.notifier).setUpdateInterval(5);

      final saved =
          jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>;
      expect(saved['password'], 'legacy-pass');
      expect(saved['update_interval_seconds'], 5);
    });
  });
}
