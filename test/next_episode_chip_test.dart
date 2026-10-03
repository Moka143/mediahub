import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/widgets/media/next_episode_chip.dart';

Episode _episode(DateTime airDate, {int season = 4, int number = 1}) => Episode(
  id: 1,
  episodeNumber: number,
  seasonNumber: season,
  name: 'Episode $number',
  airDate:
      '${airDate.year.toString().padLeft(4, '0')}-'
      '${airDate.month.toString().padLeft(2, '0')}-'
      '${airDate.day.toString().padLeft(2, '0')}',
);

Show _show({
  Episode? next,
  Episode? last,
  String status = 'Returning Series',
}) => Show(
  id: 1,
  name: 'Silo',
  nextEpisode: next,
  lastEpisode: last,
  status: status,
);

Future<String> _chipText(
  WidgetTester tester,
  Show show, {
  DateTime? now,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: NextEpisodeChip(show: show, now: now),
      ),
    ),
  );
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .join(' ');
}

void main() {
  final now = DateTime.now();

  group('NextEpisodeChip', () {
    testWidgets('an upcoming episode is described in the future tense', (
      tester,
    ) async {
      final text = await _chipText(
        tester,
        _show(next: _episode(now.add(const Duration(days: 30)))),
      );
      expect(text, contains('airs'));
      expect(text, contains('S04E01'));
    });

    testWidgets('a stale "next" episode is not still said to air', (
      tester,
    ) async {
      // The defect this guards. TMDB's `next_episode_to_air` keeps naming an
      // episode after it has aired, and the app caches show details on top of
      // that — so the chip read "airs Jul 8" in September, in the future
      // tense, two months after the fact.
      final text = await _chipText(
        tester,
        _show(next: _episode(now.subtract(const Duration(days: 66)))),
      );
      expect(text, isNot(contains('airs')));
    });

    testWidgets('a stale next falls through to the recently-aired episode', (
      tester,
    ) async {
      final text = await _chipText(
        tester,
        _show(
          next: _episode(now.subtract(const Duration(days: 66))),
          last: _episode(
            now.subtract(const Duration(days: 3)),
            season: 3,
            number: 10,
          ),
        ),
      );
      expect(text, contains('aired 3 days ago'));
      expect(text, contains('S03E10'));
    });

    testWidgets('a stale next on a returning show says it is coming back', (
      tester,
    ) async {
      // Nothing recent to fall back to, so the honest answer is the vague one
      // rather than a wrong date.
      final text = await _chipText(
        tester,
        _show(next: _episode(now.subtract(const Duration(days: 400)))),
      );
      expect(text, contains('Returning soon'));
    });

    testWidgets('today and tomorrow read naturally', (tester) async {
      expect(
        await _chipText(tester, _show(next: _episode(now))),
        contains('airs today'),
      );
      expect(
        await _chipText(
          tester,
          _show(next: _episode(now.add(const Duration(days: 1)))),
        ),
        contains('airs tomorrow'),
      );
    });

    testWidgets('counts calendar days, whatever the time of day', (
      tester,
    ) async {
      // Late on the day the clocks change: differences between local
      // midnights came up a day short across it, so tomorrow read "airs
      // today" and Saturday "in 5 days".
      final lateEvening = DateTime(2026, 3, 8, 23, 30);
      expect(
        await _chipText(
          tester,
          _show(next: _episode(DateTime(2026, 3, 9))),
          now: lateEvening,
        ),
        contains('airs tomorrow'),
      );
      expect(
        await _chipText(
          tester,
          _show(next: _episode(DateTime(2026, 3, 14))),
          now: lateEvening,
        ),
        contains('airs in 6 days'),
      );
      expect(
        await _chipText(
          tester,
          _show(last: _episode(DateTime(2026, 3, 7), season: 3, number: 9)),
          now: lateEvening,
        ),
        contains('aired yesterday'),
      );
    });

    testWidgets('an ended show with nothing to report renders nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NextEpisodeChip(show: _show(status: 'Ended')),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });
  });
}
