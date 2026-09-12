import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/widgets/connection_status_widget.dart';

void main() {
  List<String> tips(String error, TorrentEngineKind engine) =>
      ConnectionBanner.troubleshootingTips(error, engine);

  group('troubleshootingTips', () {
    // The built-in engine has no Web UI to enable, no credentials to check
    // and no host to get wrong. Advice about qBittorrent's settings sends
    // such a user looking for a program they never installed.
    test('refused connection: qBittorrent advice names qBittorrent', () {
      final t = tips('Connection refused', TorrentEngineKind.qbittorrent);
      expect(t.join(' '), contains('qBittorrent'));
      expect(t.join(' '), contains('Web UI'));
    });

    test('refused connection: built-in advice is about the port and log', () {
      final t = tips('Connection refused', TorrentEngineKind.builtin);
      expect(t.join(' '), isNot(contains('qBittorrent')));
      expect(t.join(' '), isNot(contains('Web UI')));
      expect(t.join(' '), contains('port'));
    });

    test('every branch names the engine in use, never the other one', () {
      const errors = [
        'Connection refused',
        '401 Unauthorized',
        'Connection timeout',
        'certificate error',
        'something else entirely',
      ];
      for (final error in errors) {
        expect(
          tips(error, TorrentEngineKind.builtin).join(' '),
          isNot(contains('qBittorrent')),
          reason: 'built-in advice mentioned qBittorrent for "$error"',
        );
      }
    });

    test('always returns something actionable', () {
      for (final engine in TorrentEngineKind.values) {
        expect(tips('totally unrecognised', engine), isNotEmpty);
      }
    });
  });
}
