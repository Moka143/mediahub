import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/widgets/episodes/episode_row.dart';
import 'package:mediahub/widgets/episodes/episode_status.dart';
import 'package:mediahub/widgets/episodes/number_strip.dart';

String _isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Episode _episode({String? airDate}) => Episode(
  id: 1,
  episodeNumber: 1,
  seasonNumber: 1,
  name: 'Pilot',
  airDate: airDate,
);

void main() {
  group('EpisodeRow', () {
    Future<List<int>> pumpRow(
      WidgetTester tester,
      Episode episode, {
      EpisodeStatus status = EpisodeStatus.none,
    }) async {
      final taps = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpisodeRow(
              episode: episode,
              status: status,
              onTap: () => taps.add(1),
            ),
          ),
        ),
      );
      return taps;
    }

    testWidgets('an episode that has not aired says when, and does nothing', (
      tester,
    ) async {
      final airDate = _isoDate(DateTime.now().add(const Duration(days: 30)));
      final taps = await pumpRow(tester, _episode(airDate: airDate));

      final label =
          'Airs ${DateFormat('MMM d').format(parseAirDate(airDate)!)}';
      expect(find.text(label), findsOneWidget);
      expect(find.text('Stream'), findsNothing);

      await tester.tap(find.byType(EpisodeRow));
      expect(taps, isEmpty);
    });

    testWidgets('an aired episode still offers Stream', (tester) async {
      final airDate = _isoDate(
        DateTime.now().subtract(const Duration(days: 30)),
      );
      final taps = await pumpRow(tester, _episode(airDate: airDate));

      expect(find.text('Stream'), findsOneWidget);
      await tester.tap(find.byType(EpisodeRow));
      expect(taps, [1]);
    });

    testWidgets('an episode with no date stays clickable', (tester) async {
      final taps = await pumpRow(tester, _episode());
      expect(find.text('Stream'), findsOneWidget);
      await tester.tap(find.byType(EpisodeRow));
      expect(taps, [1]);
    });

    testWidgets('an early copy already in hand still plays', (tester) async {
      final airDate = _isoDate(DateTime.now().add(const Duration(days: 30)));
      final taps = await pumpRow(
        tester,
        _episode(airDate: airDate),
        status: EpisodeStatus.downloaded,
      );
      expect(find.text('Play'), findsOneWidget);
      await tester.tap(find.byType(EpisodeRow));
      expect(taps, [1]);
    });
  });

  group('NumberStrip', () {
    Future<void> pumpStrip(WidgetTester tester, int count) async {
      await tester.binding.setSurfaceSize(const Size(400, 200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NumberStrip(
              title: 'EPISODE',
              items: [
                for (var i = 1; i <= count; i++)
                  NumberStripItem(
                    label: i.toString().padLeft(2, '0'),
                    semanticLabel: 'Episode $i',
                    onTap: () {},
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    double offset(WidgetTester tester) =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

    testWidgets('a strip that fits has no arrows', (tester) async {
      await pumpStrip(tester, 3);
      expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    });

    testWidgets('a long strip gets arrows that page it', (tester) async {
      await pumpStrip(tester, 40);
      // Both ends are drawn; only the one with more past it is live.
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
      expect(find.byTooltip('Scroll back'), findsNothing);
      expect(find.byTooltip('Scroll for more'), findsOneWidget);

      await tester.tap(find.byTooltip('Scroll for more'));
      await tester.pumpAndSettle();

      expect(offset(tester), greaterThan(0));
      expect(find.byTooltip('Scroll back'), findsOneWidget);
    });
  });
}
