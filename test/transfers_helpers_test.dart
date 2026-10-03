import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/design/app_colors.dart';
import 'package:mediahub/models/torrent_action_result.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/widgets/add_torrent_dialog.dart';
import 'package:mediahub/widgets/connection_status_widget.dart';
import 'package:mediahub/widgets/torrent_files_tab.dart';
import 'package:mediahub/widgets/torrent_info_tab.dart';
import 'package:mediahub/widgets/torrent_peers_tab.dart';
import 'package:mediahub/widgets/torrent_trackers_tab.dart';
import 'package:mediahub/widgets/transfers/engine_reporting.dart';
import 'package:mediahub/widgets/transfers/torrent_link.dart';
import 'package:mediahub/widgets/transfers/transfer_actions.dart';
import 'package:mediahub/widgets/transfers/transfer_labels.dart';
import 'package:mediahub/widgets/transfers/transfers_selection.dart';

import 'support/transfers_fakes.dart';

const _hex = '0123456789abcdef0123456789abcdef01234567';
const _base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

void main() {
  group('parseTorrentLink', () {
    test('trims, and accepts a magnet link that names a torrent', () {
      final parsed = parseTorrentLink('  magnet:?xt=urn:btih:$_hex&dn=x \n');
      expect(parsed.isValid, isTrue);
      expect(parsed.kind, TorrentLinkKind.magnet);
      expect(parsed.link, 'magnet:?xt=urn:btih:$_hex&dn=x');
    });

    test('drops the line breaks of a wrapped paste', () {
      final parsed = parseTorrentLink(
        'magnet:?xt=urn:btih:01234567\n89abcdef0123456789abcdef01234567',
      );
      expect(parsed.link, 'magnet:?xt=urn:btih:$_hex');
    });

    test('turns a bare 40-hex or 32-base32 info hash into a magnet', () {
      expect(
        parseTorrentLink(_hex.toUpperCase()).link,
        'magnet:?xt=urn:btih:$_hex',
      );
      expect(
        parseTorrentLink(_base32.toLowerCase()).link,
        'magnet:?xt=urn:btih:$_base32',
      );
      expect(parseTorrentLink(_hex).kind, TorrentLinkKind.magnet);
    });

    test('accepts an http(s) address — both engines fetch it themselves', () {
      final parsed = parseTorrentLink('https://example.org/dl/123');
      expect(parsed.isValid, isTrue);
      expect(parsed.kind, TorrentLinkKind.url);
    });

    test('turns away what the engine could only reject, with a reason', () {
      for (final junk in [
        '',
        '   ',
        'hello world',
        'magnet:?dn=no-hash-here',
        'magnet:?xt=urn:btih:tooshort',
        'https://',
        'ftp://example.org/file.torrent',
        '/Users/me/Downloads/show.torrent',
      ]) {
        final parsed = parseTorrentLink(junk);
        expect(parsed.isValid, isFalse, reason: junk);
        expect(parsed.problem, isNotEmpty, reason: junk);
      }
    });

    test('a local .torrent path is pointed at the file chooser', () {
      expect(
        parseTorrentLink('/tmp/show.torrent').problem,
        contains('Choose .torrent file'),
      );
    });

    test('only a magnet link is worth offering from the clipboard', () {
      expect(looksLikeMagnet('magnet:?xt=urn:btih:$_hex'), isTrue);
      expect(looksLikeMagnet('https://example.org/x.torrent'), isFalse);
      expect(looksLikeMagnet(_hex), isFalse, reason: 'too ambiguous');
      expect(looksLikeMagnet('magnet:?dn=broken'), isFalse);
      expect(looksLikeMagnet(null), isFalse);
    });
  });

  group('add failure wording', () {
    test('never shows the raw cause', () {
      const raw =
          'DioException [connection error]: SocketException: Connection '
          'refused (OS Error: Connection refused, errno = 61)';
      final message = addTorrentFailureMessage(
        TorrentLinkKind.magnet,
        const TorrentActionResult.failure(raw),
      );
      expect(message, isNot(contains('Exception')));
      expect(message, contains("isn't reachable"));
    });

    test('an engine that just said no gets advice for what was added', () {
      const refused = TorrentActionResult.failure(
        'qBittorrent rejected the request',
      );
      expect(
        addTorrentFailureMessage(TorrentLinkKind.magnet, refused),
        contains('magnet link'),
      );
      expect(
        addTorrentFailureMessage(TorrentLinkKind.url, refused),
        contains('address'),
      );
      expect(addTorrentFailureMessage(null, refused), contains('.torrent'));
    });
  });

  group('transfer action failures', () {
    test('say what failed and why, in words', () {
      final message = transferActionFailure(
        TransferAction.pause,
        const TorrentActionResult.failure('qBittorrent timed out'),
      );
      expect(message, startsWith("Couldn't pause this transfer."));
      expect(message, contains('too long'));
    });

    test('count the transfers in a bulk action', () {
      expect(
        transferActionFailure(
          TransferAction.delete,
          const TorrentActionResult.failure('nope'),
          count: 3,
        ),
        startsWith("Couldn't delete 3 transfers."),
      );
    });

    test('an exception text is classified, not printed', () {
      final reason = transferFailureReason(
        "SocketException: Failed host lookup: 'localhost'",
      );
      expect(reason, isNot(contains('SocketException')));
    });
  });

  group('row selection', () {
    test('Shift extends, ⌘/Ctrl toggles, a plain click opens', () {
      expect(
        transfersClickIntent(
          selectionMode: false,
          shiftHeld: false,
          toggleModifierHeld: false,
        ),
        TransfersClick.open,
      );
      expect(
        transfersClickIntent(
          selectionMode: false,
          shiftHeld: false,
          toggleModifierHeld: true,
        ),
        TransfersClick.toggle,
      );
      expect(
        transfersClickIntent(
          selectionMode: false,
          shiftHeld: true,
          toggleModifierHeld: false,
        ),
        TransfersClick.extend,
      );
    });

    test('during a selection a plain click toggles', () {
      expect(
        transfersClickIntent(
          selectionMode: true,
          shiftHeld: false,
          toggleModifierHeld: false,
        ),
        TransfersClick.toggle,
      );
    });

    test('a range runs from the anchor to the target, either direction', () {
      const order = ['a', 'b', 'c', 'd', 'e'];
      expect(transfersRange(order, 'b', 'd'), ['b', 'c', 'd']);
      expect(transfersRange(order, 'd', 'b'), ['b', 'c', 'd']);
      expect(transfersRange(order, null, 'c'), ['c']);
      expect(transfersRange(order, 'gone', 'c'), ['c']);
      expect(transfersRange(order, 'a', 'gone'), isEmpty);
    });
  });

  group('labels', () {
    test('only a torrent with data arriving counts as transferring', () {
      expect(isTransferring(testTorrent()), isTrue);
      expect(isTransferring(testTorrent(state: TorrentState.forcedDL)), isTrue);
      for (final state in [
        TorrentState.stalledDL,
        TorrentState.queuedDL,
        TorrentState.metaDL,
        TorrentState.pausedDL,
        TorrentState.uploading,
      ]) {
        expect(isTransferring(testTorrent(state: state)), isFalse);
      }
    });

    test('ETA: a duration while downloading, a dash when done', () {
      expect(transferEtaLabel(testTorrent(eta: 90)), '1m 30s');
      expect(transferEtaLabel(testTorrent(eta: 8640000)), '∞');
      expect(
        transferEtaLabel(
          testTorrent(state: TorrentState.uploading, eta: 8640000),
        ),
        '—',
      );
      expect(transferEtaLabel(testTorrent(state: TorrentState.pausedDL)), '—');
    });

    test('one wording for who a torrent is connected to', () {
      final torrent = testTorrent(numSeeds: 12, numLeeches: 3);
      expect(swarmLabel(torrent, EngineReporting.full), '12 seeds · 3 peers');
      // The built-in engine puts every connected peer in numSeeds.
      expect(swarmLabel(torrent, EngineReporting.builtIn), '12 peers');
      expect(
        swarmLabel(
          testTorrent(numSeeds: 1, numLeeches: 1),
          EngineReporting.full,
        ),
        '1 seed · 1 peer',
      );
    });
  });

  group('peers', () {
    test('country flags work for qBittorrent’s lower-case codes', () {
      expect(countryFlag('us'), '🇺🇸');
      expect(countryFlag('US'), '🇺🇸');
      expect(countryFlag(' de '), '🇩🇪');
    });

    test('no flag for anything that is not two letters', () {
      for (final code in ['', 'u', 'usa', 'u1', '--', 'ü1']) {
        expect(countryFlag(code), isEmpty, reason: code);
      }
    });
  });

  group('trackers', () {
    test('each status has its own icon and colour', () {
      final styles = [for (var s = 0; s <= 6; s++) trackerStatusStyle(s)];
      expect(styles.map((s) => s.icon).toSet(), hasLength(7));
      expect(trackerStatusStyle(2).label, 'Working');
      expect(trackerStatusStyle(2).tone, AppColors.ok);
    });

    test('"Not working" is never drawn with a check mark', () {
      expect(trackerStatusStyle(4).icon, isNot(trackerStatusStyle(2).icon));
      expect(trackerStatusStyle(4).tone, AppColors.err);
    });

    test('codes 5 and 6 are errors, not "Disabled"', () {
      expect(trackerStatusStyle(5).label, 'Tracker error');
      expect(trackerStatusStyle(6).label, 'Unreachable');
      expect(trackerStatusStyle(5).tone, AppColors.err);
      expect(trackerStatusStyle(6).tone, AppColors.err);
      expect(trackerStatusStyle(99).label, 'Unknown');
    });
  });

  group('file priorities', () {
    test('the built-in engine offers only Download and Skip', () {
      final choices = filePriorityChoices(ranked: false);
      expect(choices.map((c) => c.label), ['Download', 'Skip']);
      expect(choices.map((c) => c.priority), [
        FilePriority.normal,
        FilePriority.doNotDownload,
      ]);
    });

    test('qBittorrent offers its full scale', () {
      expect(filePriorityChoices(ranked: true).map((c) => c.label), [
        'Maximum',
        'High',
        'Normal',
        'Skip',
      ]);
    });

    test('a file reads as the engine reports it', () {
      expect(filePriorityChoice(0, ranked: false).label, 'Skip');
      expect(filePriorityChoice(1, ranked: false).label, 'Download');
      expect(filePriorityChoice(7, ranked: true).label, 'Maximum');
      expect(filePriorityChoice(6, ranked: true).label, 'High');
      expect(filePriorityChoice(1, ranked: true).label, 'Normal');
    });

    test('videos are recognised by the library scanner’s list', () {
      for (final name in ['a.mkv', 'b.ts', 'c.MPG', 'd.mpeg', 'e.3gp']) {
        expect(isVideoFile(testFile(0, name)), isTrue, reason: name);
      }
      expect(isVideoFile(testFile(0, 'notes.nfo')), isFalse);
    });
  });

  group('info tab', () {
    List<String> labels(
      Iterable<({String title, List<InfoField> fields})> sections,
    ) => [
      for (final section in sections) ...[
        section.title,
        for (final field in section.fields) field.label,
      ],
    ];

    test('rows the built-in engine never reports are left out', () {
      final sections = torrentInfoSections(
        testTorrent(progress: 1, state: TorrentState.uploading),
        EngineReporting.builtIn,
      );
      final shown = labels(sections);
      expect(shown, isNot(contains('Added on')));
      expect(shown, isNot(contains('Last activity')));
      expect(shown, isNot(contains('Piece size')));
      expect(shown, isNot(contains('Dates')), reason: 'nothing left in it');
      expect(shown, contains('Connected peers'));
      expect(shown, isNot(contains('Seeds')));
    });

    test('what the engine does report is shown', () {
      final sections = torrentInfoSections(
        testTorrent(
          addedOn: 1700000000,
          lastActivity: 1700000500,
          pieceSize: 4 * 1024 * 1024,
          piecesNum: 100,
          piecesHave: 40,
        ),
        EngineReporting.full,
      );
      final all = [for (final s in sections) ...s.fields];
      expect(labels(sections), containsAll(['Added on', 'Last activity']));
      expect(
        all.firstWhere((f) => f.label == 'Pieces').value,
        '40 of 100 downloaded',
      );
      expect(labels(sections), containsAll(['Seeds', 'Peers']));
    });
  });

  group('engine version label', () {
    test('one "v", and no version for an engine name', () {
      expect(engineVersionLabel('v4.6.2'), 'v4.6.2');
      expect(engineVersionLabel('4.6.2'), 'v4.6.2');
      expect(engineVersionLabel('rqbit'), isNull);
      expect(engineVersionLabel(null), isNull);
    });
  });
}
