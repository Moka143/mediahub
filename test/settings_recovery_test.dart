import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/settings.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/utils/platform_utils.dart';

/// Two pieces of defensive parsing that both exist because their failure mode
/// is silent and expensive.
void main() {
  group('AppSettings.fromJson', () {
    test('a corrupt enum index does not cost the user their settings', () {
      // `TorrentFilter.values[9]` throws, and the only catch is in
      // SettingsNotifier._loadSettings — which resets *everything*. One stale
      // index used to take the host, port and credentials with it.
      final settings = AppSettings.fromJson({
        'host': 'nas.local',
        'port': 9091,
        'username': 'me',
        'default_filter': 99,
        'default_sort': -1,
      });

      expect(settings.host, 'nas.local');
      expect(settings.port, 9091);
      expect(settings.username, 'me');
      expect(settings.defaultFilter, TorrentFilter.all);
      expect(settings.defaultSort, TorrentSort.addedOn);
    });

    test('a non-integer index falls back too', () {
      final settings = AppSettings.fromJson({'default_filter': 'downloading'});
      expect(settings.defaultFilter, TorrentFilter.all);
    });

    test('a valid index is still honoured', () {
      final settings = AppSettings.fromJson({
        'default_filter': TorrentFilter.seeding.index,
        'default_sort': TorrentSort.name.index,
      });
      expect(settings.defaultFilter, TorrentFilter.seeding);
      expect(settings.defaultSort, TorrentSort.name);
    });
  });

  group('PlatformUtils.isLocalHost', () {
    // Decides whether the app may launch — and repeatedly restart —
    // a qBittorrent process. Getting it wrong against a remote host meant
    // spawning a local instance every 5 s.
    test('recognises the ways of saying "this machine"', () {
      for (final host in ['localhost', 'LOCALHOST', '127.0.0.1', '::1', ' ']) {
        expect(PlatformUtils.isLocalHost(host), isTrue, reason: host);
      }
    });

    test('anything else is somebody else\'s process', () {
      for (final host in ['nas.local', '192.168.1.50', 'qbit.example.com']) {
        expect(PlatformUtils.isLocalHost(host), isFalse, reason: host);
      }
    });
  });
}
