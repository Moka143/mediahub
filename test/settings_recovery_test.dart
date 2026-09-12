import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/settings.dart';
import 'package:mediahub/providers/settings_provider.dart';
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

  group('engine selection', () {
    test('an install with no engine_kind key stays on qBittorrent', () {
      // The upgrade path that matters: an existing user has a configured
      // qBittorrent with a library in it. Switching them to the built-in
      // engine on update would look like every torrent disappearing.
      final settings = AppSettings.fromJson({'host': 'localhost'});
      expect(settings.engineKind, TorrentEngineKind.qbittorrent);
    });

    test('the chosen engine survives a save/load round trip', () {
      final saved = AppSettings(
        engineKind: TorrentEngineKind.builtin,
        rqbitPort: 4040,
        rqbitPath: '/opt/rqbit',
      );
      final loaded = AppSettings.fromJson(saved.toJson());
      expect(loaded.engineKind, TorrentEngineKind.builtin);
      expect(loaded.rqbitPort, 4040);
      expect(loaded.rqbitPath, '/opt/rqbit');
      expect(loaded, equals(saved));
    });

    test('a corrupt engine_kind falls back rather than throwing', () {
      expect(
        AppSettings.fromJson({'engine_kind': 42}).engineKind,
        TorrentEngineKind.qbittorrent,
      );
      expect(
        AppSettings.fromJson({'engine_kind': 'builtin'}).engineKind,
        TorrentEngineKind.qbittorrent,
      );
    });

    test('the engine port defaults without clobbering the qBittorrent one', () {
      // Two separate ports on purpose: switching engines must not require
      // re-entering the other one's connection details.
      final settings = AppSettings.fromJson({'port': 8080});
      expect(settings.port, 8080);
      expect(settings.rqbitPort, AppConstants.defaultRqbitPort);
    });
  });

  group('fresh install defaults', () {
    test('a brand-new install gets the built-in engine', () {
      // Nothing saved means no existing qBittorrent and no library in it.
      // Steering such a user to qBittorrent would mean installing a second
      // program, enabling its Web UI and inventing a password before they
      // can watch anything.
      expect(
        SettingsNotifier.freshInstallDefaults().engineKind,
        TorrentEngineKind.builtin,
      );
    });

    test('the model itself still defaults to qBittorrent', () {
      // The asymmetry is the upgrade guard: `AppSettings.fromJson` on an
      // existing blob with no engine_kind key must not switch anyone.
      expect(AppSettings().engineKind, TorrentEngineKind.qbittorrent);
      expect(
        AppSettings.fromJson(const {'host': 'localhost'}).engineKind,
        TorrentEngineKind.qbittorrent,
      );
    });
  });

  group('engine migration', () {
    AppSettings migrate(Map<String, dynamic> raw) =>
        SettingsNotifier.migrateEngine(AppSettings.fromJson(raw), raw);

    test(
      'an install that predates the setting moves to the built-in engine',
      () {
        // No `engine_kind` key means the blob was written by a build where
        // qBittorrent was the only option — the user never chose it.
        final s = migrate(const {'host': 'localhost', 'port': 8080});
        expect(s.engineKind, TorrentEngineKind.builtin);
      },
    );

    test('the migration keeps every qBittorrent setting', () {
      // Switching back has to restore exactly the previous setup, because
      // torrents already running there will not show up until they do.
      final s = migrate(const {
        'host': 'nas.local',
        'port': 9091,
        'username': 'me',
        'qbittorrent_path': '/opt/qbittorrent',
        'auto_start_qbittorrent': false,
      });
      expect(s.host, 'nas.local');
      expect(s.port, 9091);
      expect(s.username, 'me');
      expect(s.qbittorrentPath, '/opt/qbittorrent');
      expect(s.autoStartQBittorrent, isFalse);
    });

    test('it arms the one-time notice', () {
      // Silence would show an empty Transfers list first, which reads as
      // data loss rather than as a changed backend.
      expect(migrate(const {'host': 'x'}).engineMigrationNoticeSeen, isFalse);
    });

    test('someone who chose qBittorrent is left alone', () {
      final raw = {
        'host': 'x',
        'engine_kind': TorrentEngineKind.qbittorrent.index,
      };
      final s = migrate(raw);
      expect(s.engineKind, TorrentEngineKind.qbittorrent);
      expect(s.engineMigrationNoticeSeen, isTrue, reason: 'no notice for them');
    });

    test('it is self-limiting — a migrated install is not migrated again', () {
      // The first save writes `engine_kind`, and its presence is the whole
      // condition. No separate "have we migrated" flag to keep honest.
      final once = migrate(const {'host': 'x'});
      final saved = once.toJson();
      expect(saved.containsKey('engine_kind'), isTrue);

      final twice = SettingsNotifier.migrateEngine(
        AppSettings.fromJson(saved),
        saved,
      );
      expect(twice.engineKind, TorrentEngineKind.builtin);
      expect(
        twice.engineMigrationNoticeSeen,
        isFalse,
        reason: 'still unseen here because nothing marked it seen yet',
      );

      // And once the notice has been marked seen, it stays seen.
      final acknowledged = once.copyWith(engineMigrationNoticeSeen: true);
      final reloaded = AppSettings.fromJson(acknowledged.toJson());
      expect(reloaded.engineMigrationNoticeSeen, isTrue);
    });

    test('a fresh install is never told about a migration', () {
      expect(
        SettingsNotifier.freshInstallDefaults().engineMigrationNoticeSeen,
        isTrue,
      );
    });
  });
}
