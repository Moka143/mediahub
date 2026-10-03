import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/navigation_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/screens/downloads_screen.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/widgets/mediahub_torrent_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/transfers_fakes.dart';

const _connected = ConnectionState(status: ConnectionStatus.connected);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  List<Override> overrides({
    ConnectionState connection = _connected,
    List<Torrent> torrents = const [],
  }) => [
    sharedPreferencesProvider.overrideWithValue(prefs),
    connectionProvider.overrideWith(() => FakeConnection(connection)),
    torrentListProvider.overrideWith(() => FakeTorrentList(torrents)),
    torrentEngineProvider.overrideWithValue(
      FakeEngine(capabilities: builtinCapabilities),
    ),
  ];

  void useWindow(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('engine offline', () {
    testWidgets('says why, with a way out, instead of "No transfers yet"', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          const DownloadsScreen(),
          overrides: overrides(
            connection: const ConnectionState(
              status: ConnectionStatus.error,
              errorMessage: "The built-in engine isn't running.",
              failure: ConnectionFailure.engineNotRunning,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text("The built-in engine isn't running"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.text('No transfers yet'), findsNothing);
      expect(find.textContaining('qBittorrent'), findsNothing);

      await tester.tap(find.text('Show troubleshooting tips'));
      await tester.pumpAndSettle();
      expect(
        find.text('Try a different engine port in Settings'),
        findsOneWidget,
      );
    });

    testWidgets('while connecting, says so rather than showing an error', (
      tester,
    ) async {
      await tester.pumpWidget(
        testApp(
          const DownloadsScreen(),
          overrides: overrides(
            connection: const ConnectionState(
              status: ConnectionStatus.connecting,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Connecting to the built-in engine…'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });
  });

  group('empty list', () {
    testWidgets('no transfers at all points to Shows', (tester) async {
      await tester.pumpWidget(
        testApp(const DownloadsScreen(), overrides: overrides()),
      );
      await tester.pumpAndSettle();

      expect(find.text('No transfers yet'), findsOneWidget);
      await tester.tap(find.text('Browse shows'));
      await tester.pump();
      expect(
        tester.container().read(currentTabIndexProvider),
        AppTab.shows.index,
      );
    });

    testWidgets('a filter that matches nothing does not claim the list is '
        'empty', (tester) async {
      await tester.pumpWidget(
        testApp(
          const DownloadsScreen(),
          overrides: overrides(
            torrents: [testTorrent(state: TorrentState.pausedDL)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester
          .container()
          .read(currentFilterProvider.notifier)
          .set(TorrentFilter.seeding);
      await tester.pumpAndSettle();

      expect(find.text('No transfers yet'), findsNothing);
      expect(find.text('Show all'), findsOneWidget);
    });
  });

  group('side by side', () {
    testWidgets('from 1000px the details sit beside the list', (tester) async {
      useWindow(tester, const Size(1100, 800));
      await tester.pumpWidget(
        testApp(
          const DownloadsScreen(),
          overrides: overrides(
            torrents: [testTorrent(state: TorrentState.pausedDL)],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Select a transfer to see its details'), findsOneWidget);
    });

    testWidgets('Ctrl-click and Shift-click build a selection; Esc ends it', (
      tester,
    ) async {
      useWindow(tester, const Size(1400, 900));
      // Newest first is the default order; distinct add times keep it
      // a, b, c, d.
      Torrent named(String name, int addedOn) => testTorrent(
        hash: name * 40,
        name: '$name.mkv',
        state: TorrentState.pausedDL,
        addedOn: addedOn,
      );
      await tester.pumpWidget(
        testApp(
          const DownloadsScreen(),
          overrides: overrides(
            torrents: [
              named('a', 4),
              named('b', 3),
              named('c', 2),
              named('d', 1),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder rowNamed(String name) => find.descendant(
        of: find.byType(MediaHubTorrentRow),
        matching: find.text('$name.mkv'),
      );
      Set<String> checked() =>
          tester.container().read(selectedTorrentHashesProvider);

      // A plain click opens a in the details pane.
      await tester.tap(rowNamed('a'));
      await tester.pumpAndSettle();
      expect(tester.container().read(selectedTorrentHashProvider), 'a' * 40);
      expect(checked(), isEmpty);

      // Ctrl-click c: the open transfer joins the selection, as in a file
      // manager.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(rowNamed('c'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(checked(), {'a' * 40, 'c' * 40});

      // Shift-click d extends from c.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(rowNamed('d'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(checked(), {'a' * 40, 'c' * 40, 'd' * 40});

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(checked(), isEmpty);
    });
  });
}
