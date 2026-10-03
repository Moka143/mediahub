import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/widgets/connection_status_widget.dart';

void main() {
  EngineIssue issue(String error, TorrentEngineKind engine) =>
      EngineIssue.describe(error, engine);
  String advice(EngineIssue issue) =>
      [issue.title, issue.hint, ...issue.tips].join(' ');

  group('troubleshooting tips', () {
    // The built-in engine has no Web UI to enable, no credentials to check
    // and no host to get wrong. Advice about qBittorrent's settings sends
    // such a user looking for a program they never installed.
    test('refused connection: qBittorrent advice names qBittorrent', () {
      final t = issue('Connection refused', TorrentEngineKind.qbittorrent).tips;
      expect(t.join(' '), contains('qBittorrent'));
      expect(t.join(' '), contains('Web UI'));
    });

    test('refused connection: built-in advice is about the port and log', () {
      final t = issue('Connection refused', TorrentEngineKind.builtin).tips;
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
        'Connection lost',
        'something else entirely',
        'Failed to authenticate. Check username/password in Settings.',
      ];
      for (final error in errors) {
        expect(
          advice(issue(error, TorrentEngineKind.builtin)),
          isNot(contains('qBittorrent')),
          reason: 'built-in advice mentioned qBittorrent for "$error"',
        );
      }
    });

    test('always returns something actionable', () {
      for (final engine in TorrentEngineKind.values) {
        for (final trouble in EngineTrouble.values) {
          final described = EngineIssue.forTrouble(trouble, engine);
          expect(described.title, isNotEmpty);
          expect(described.hint, isNotEmpty);
          expect(described.tips, isNotEmpty);
        }
      }
    });
  });

  group('classifying the error once', () {
    test('the hint and the tips come from the same reading', () {
      final refused = issue('Connection refused', TorrentEngineKind.builtin);
      expect(refused.trouble, EngineTrouble.notRunning);
      expect(refused.hint, contains('port'));
      expect(refused.tips.join(' '), contains('port'));
    });

    test('the built-in engine has no login to get wrong', () {
      // Before the engine-aware messages, a built-in engine that did not
      // answer surfaced as "Failed to authenticate. Check username/password".
      final described = issue(
        'Failed to authenticate. Check username/password in Settings.',
        TorrentEngineKind.builtin,
      );
      expect(described.trouble, EngineTrouble.notRunning);
      expect(advice(described), isNot(contains('password')));
      expect(
        issue('401 Unauthorized', TorrentEngineKind.qbittorrent).trouble,
        EngineTrouble.rejectedLogin,
      );
    });

    test('a port that contains 401 or 403 is not a login error', () {
      expect(
        issue(
          'Cannot connect to http://localhost:4030',
          TorrentEngineKind.qbittorrent,
        ).trouble,
        EngineTrouble.notRunning,
      );
    });

    test('the recorded failure wins over the wording', () {
      const state = ConnectionState(
        status: ConnectionStatus.error,
        errorMessage: 'some sentence that matches nothing',
        failure: ConnectionFailure.timedOut,
      );
      expect(
        engineTroubleFor(state, TorrentEngineKind.builtin),
        EngineTrouble.slow,
      );
      expect(
        engineTroubleFor(
          const ConnectionState(
            status: ConnectionStatus.error,
            failure: ConnectionFailure.loginRejected,
          ),
          TorrentEngineKind.builtin,
        ),
        EngineTrouble.notRunning,
        reason: 'the built-in engine has no login',
      );
      expect(
        engineTroubleFor(
          const ConnectionState(
            status: ConnectionStatus.error,
            failure: ConnectionFailure.engineNotFound,
          ),
          TorrentEngineKind.qbittorrent,
        ),
        EngineTrouble.notFound,
      );
    });
  });

  group('copy', () {
    test('desktop wording, and no "Configure connection settings" for '
        'the built-in engine', () {
      for (final engine in TorrentEngineKind.values) {
        for (final trouble in EngineTrouble.values) {
          final text = advice(EngineIssue.forTrouble(trouble, engine));
          expect(text, isNot(contains('Tap')));
          expect(text, isNot(contains('...')));
          if (engine == TorrentEngineKind.builtin) {
            expect(text, isNot(contains('Configure connection settings')));
          }
        }
      }
    });
  });
}
