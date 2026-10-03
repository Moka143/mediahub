import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/utils/formatters.dart';
import 'package:mediahub/widgets/mediahub_torrent_row.dart';

import 'support/transfers_fakes.dart';

/// The Transfers row: idle when nothing moves, reachable without a mouse,
/// and lined up with its header.
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  MediaHubTorrentRow row(
    Torrent torrent, {
    VoidCallback? onTap,
    VoidCallback? onDelete,
    VoidCallback? onPause,
  }) {
    return MediaHubTorrentRow(
      torrent: torrent,
      selected: false,
      onTap: onTap ?? () {},
      onLongPress: () {},
      onPause: onPause ?? () {},
      onResume: () {},
      onDelete: onDelete ?? () {},
    );
  }

  double actionsOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  testWidgets('the status dot animates only while data is arriving', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(row(testTorrent(state: TorrentState.pausedDL))),
    );
    await tester.pump();
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'a paused row must let the app go idle',
    );

    await tester.pumpWidget(app(row(testTorrent(dlspeed: 4096))));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(
      app(row(testTorrent(state: TorrentState.stalledDL))),
    );
    await tester.pump();
    expect(
      tester.binding.transientCallbackCount,
      0,
      reason: 'stalled is waiting, not working',
    );
  });

  testWidgets('keyboard focus reveals the hover-only actions', (tester) async {
    await tester.pumpWidget(
      app(row(testTorrent(state: TorrentState.pausedDL))),
    );
    expect(actionsOpacity(tester), 0.3);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(actionsOpacity(tester), 1.0);

    // Still lit with focus on the row's own buttons.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(actionsOpacity(tester), 1.0);
  });

  testWidgets('Enter runs the row; Delete asks to delete it', (tester) async {
    var taps = 0;
    var deletes = 0;
    await tester.pumpWidget(
      app(
        row(
          testTorrent(state: TorrentState.pausedDL),
          onTap: () => taps++,
          onDelete: () => deletes++,
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(deletes, 1);
  });

  testWidgets('right click opens the row menu', (tester) async {
    var deletes = 0;
    await tester.pumpWidget(
      app(
        row(
          testTorrent(state: TorrentState.pausedDL),
          onDelete: () => deletes++,
        ),
      ),
    );

    await tester.tap(
      find.byType(MediaHubTorrentRow),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Select'), findsOneWidget);

    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });

  testWidgets('the header and the rows share their column widths', (
    tester,
  ) async {
    final torrent = testTorrent(state: TorrentState.pausedDL);
    await tester.pumpWidget(
      app(
        Column(
          children: [
            MediaHubTorrentHeader(
              sortKey: TorrentSort.name,
              ascending: true,
              onSortKeyTap: (_) {},
            ),
            row(torrent),
          ],
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.text('SIZE')).dx,
      tester.getTopLeft(find.text(Formatters.formatBytes(torrent.size))).dx,
    );
  });
}
