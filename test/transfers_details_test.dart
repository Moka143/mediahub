import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/models/torrent_action_result.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/screens/torrent_details_screen.dart';
import 'package:mediahub/services/torrent_engine.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/widgets/editorial/editorial.dart';
import 'package:mediahub/widgets/torrent_files_tab.dart';
import 'package:mediahub/widgets/transfers/engine_reporting.dart';

import 'support/transfers_fakes.dart';

const _hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _connected = ConnectionState(status: ConnectionStatus.connected);

class _Selected extends SelectedTorrentHashNotifier {
  _Selected(this._initial);

  final String? _initial;

  @override
  String? build() => _initial;
}

class _FailingPause extends FakeTorrentList {
  _FailingPause(super.initial);

  @override
  Future<TorrentActionResult> pauseTorrents(List<String> hashes) async =>
      const TorrentActionResult.failure("Can't reach the torrent engine");
}

/// Stands in for the Transfers split view: the details pane while something
/// is selected, a placeholder once nothing is.
class _Pane extends ConsumerWidget {
  const _Pane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hash = ref.watch(selectedTorrentHashProvider);
    return hash == null
        ? const Text('Nothing selected')
        : TorrentDetailsScreen(torrentHash: hash, embedded: true);
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  List<Override> overrides(
    FakeTorrentList list, {
    String? selected,
    FakeEngine? engine,
  }) => [
    torrentListProvider.overrideWith(() => list),
    torrentEngineProvider.overrideWithValue(
      engine ?? FakeEngine(capabilities: builtinCapabilities),
    ),
    connectionProvider.overrideWith(() => FakeConnection(_connected)),
    engineReportingProvider.overrideWithValue(EngineReporting.builtIn),
    selectedTorrentHashProvider.overrideWith(() => _Selected(selected)),
  ];

  Future<void> confirmDelete(WidgetTester tester) async {
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(EditorialButton, 'Delete'));
    await tester.pumpAndSettle();
  }

  group('deleting', () {
    testWidgets('beside the list: clears the selection and pops nothing', (
      tester,
    ) async {
      final list = FakeTorrentList([
        testTorrent(hash: _hash, state: TorrentState.pausedDL),
      ]);
      final pops = PopRecorder();
      await tester.pumpWidget(
        testApp(
          const _Pane(),
          overrides: overrides(list, selected: _hash),
          observers: [pops],
        ),
      );
      await tester.pumpAndSettle();

      await confirmDelete(tester);

      expect(list.deleteCalls, [
        [_hash],
      ]);
      expect(tester.container().read(selectedTorrentHashProvider), isNull);
      expect(find.text('Nothing selected'), findsOneWidget);
      // The confirm dialog closed; the app's only page did not.
      expect(pops.popped.whereType<PageRoute<dynamic>>(), isEmpty);
    });

    testWidgets('on its own page: goes back to the list', (tester) async {
      final list = FakeTorrentList([
        testTorrent(hash: _hash, state: TorrentState.pausedDL),
      ]);
      await tester.pumpWidget(
        testApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const TorrentDetailsScreen(torrentHash: _hash),
                ),
              ),
              child: const Text('open'),
            ),
          ),
          overrides: overrides(list),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(TorrentDetailsScreen), findsOneWidget);

      await confirmDelete(tester);

      expect(find.byType(TorrentDetailsScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });

  testWidgets('a failed pause in the details pane says why', (tester) async {
    final list = _FailingPause([testTorrent(hash: _hash)]);
    await tester.pumpWidget(
      testApp(const _Pane(), overrides: overrides(list, selected: _hash)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(EditorialButton, 'Pause'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        "Couldn't pause this transfer. The torrent engine isn't reachable "
        'right now.',
      ),
      findsOneWidget,
    );
  });

  group('files tab', () {
    Future<void> pumpFiles(WidgetTester tester, FakeEngine engine) async {
      await tester.pumpWidget(
        testApp(
          const TorrentFilesTab(torrentHash: _hash),
          overrides: [
            torrentEngineProvider.overrideWithValue(engine),
            connectionProvider.overrideWith(() => FakeConnection(_connected)),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the built-in engine is offered Download and Skip only', (
      tester,
    ) async {
      await pumpFiles(
        tester,
        FakeEngine(
          capabilities: builtinCapabilities,
          files: [testFile(0, 'a.mkv'), testFile(1, 'b.nfo')],
        ),
      );

      await tester.tap(find.text('Download').first);
      await tester.pumpAndSettle();

      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('High'), findsNothing);
      expect(find.text('Maximum'), findsNothing);
    });

    testWidgets('qBittorrent is offered its full scale', (tester) async {
      await pumpFiles(
        tester,
        FakeEngine(files: [testFile(0, 'a.mkv'), testFile(1, 'b.nfo')]),
      );

      await tester.tap(find.text('Normal').first);
      await tester.pumpAndSettle();

      for (final label in ['Maximum', 'High', 'Skip']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('a change the engine refuses is reported', (tester) async {
      final engine = FakeEngine(
        capabilities: builtinCapabilities,
        files: [testFile(0, 'a.mkv'), testFile(1, 'b.nfo')],
        priorityResult: false,
      );
      await pumpFiles(tester, engine);

      await tester.tap(find.text('Download').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(engine.priorityCalls.single.ids, [1]);
      expect(engine.priorityCalls.single.priority, 0);
      expect(
        find.text(
          "Couldn't change which files download. Try again in a moment.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('skipping the last file is explained, not sent', (
      tester,
    ) async {
      final engine = FakeEngine(
        capabilities: builtinCapabilities,
        files: [testFile(0, 'a.mkv'), testFile(1, 'b.nfo', priority: 0)],
      );
      await pumpFiles(tester, engine);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip').last);
      await tester.pumpAndSettle();

      expect(engine.priorityCalls, isEmpty);
      expect(
        find.text('At least one file has to stay selected for download.'),
        findsOneWidget,
      );
    });

    testWidgets('the bulk priority button is a working button', (tester) async {
      await pumpFiles(
        tester,
        FakeEngine(
          capabilities: const EngineCapabilities(),
          files: [testFile(0, 'a.mkv'), testFile(1, 'b.nfo')],
        ),
      );

      await tester.tap(find.text('Select files'));
      await tester.pumpAndSettle();
      EditorialButton setPriority() => tester.widget<EditorialButton>(
        find.widgetWithText(EditorialButton, 'Set priority'),
      );
      expect(setPriority().onPressed, isNull, reason: 'nothing ticked yet');

      await tester.tap(find.text('a.mkv'));
      await tester.pumpAndSettle();
      expect(setPriority().onPressed, isNotNull);

      await tester.tap(find.text('Set priority'));
      await tester.pumpAndSettle();
      expect(find.text('Maximum'), findsOneWidget);
    });
  });
}
