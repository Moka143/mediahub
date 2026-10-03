import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/providers/calendar_provider.dart';
import 'package:mediahub/screens/calendar_screen.dart';

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Episode _ep(int number, DateTime airDate, {int season = 1}) => Episode(
  id: season * 1000 + number,
  episodeNumber: number,
  seasonNumber: season,
  name: 'Episode $number',
  airDate: _ymd(airDate),
);

CalendarEpisode _cal(DateTime airDate, {String show = 'Silo', int ep = 1}) =>
    CalendarEpisode(
      showId: 1,
      showName: show,
      seasonNumber: 2,
      episodeNumber: ep,
      airDate: dateOnly(airDate),
    );

void main() {
  final today = DateTime(2026, 10, 3);

  group('buildCalendar', () {
    test('keeps episodes in the window, remembers the next one after it, '
        'and reports a show that failed', () async {
      final data = await buildCalendar(
        showIds: [1, 2],
        today: today,
        fetchShow: (id) async {
          if (id == 2) throw Exception('connection error');
          return Show(id: 1, name: 'Silo', numberOfSeasons: 1);
        },
        fetchSeason: (id, season) async => [
          _ep(1, today.subtract(const Duration(days: 1))),
          _ep(2, today.add(const Duration(days: 3))),
          _ep(3, today.add(const Duration(days: 40))),
          _ep(4, today.subtract(const Duration(days: 20))),
        ],
      );

      expect(data.showCount, 2);
      expect(data.failures.map((f) => f.showId), [2]);
      expect(data.allFailed, isFalse);
      expect(data.on(today.subtract(const Duration(days: 1))), hasLength(1));
      expect(data.on(today.add(const Duration(days: 3))), hasLength(1));
      // Outside the window: neither shown nor lost.
      expect(data.nextAfterWindow?.episodeNumber, 3);
      expect(
        data.between(today.subtract(const Duration(days: 30)), today),
        hasLength(1),
      );
    });

    test(
      'every show failing is "couldn\'t load", not "nothing airing"',
      () async {
        final data = await buildCalendar(
          showIds: [1, 2, 3],
          today: today,
          fetchShow: (id) async => throw Exception('offline'),
          fetchSeason: (id, season) async => const [],
        );
        expect(data.allFailed, isTrue);
        expect(data.byDay, isEmpty);
      },
    );

    test(
      'fetches shows in parallel, but no more than the limit at once',
      () async {
        var inFlight = 0;
        var peak = 0;
        await buildCalendar(
          showIds: List.generate(10, (i) => i + 1),
          today: today,
          concurrency: 3,
          fetchShow: (id) async {
            inFlight++;
            peak = inFlight > peak ? inFlight : peak;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            inFlight--;
            return Show(id: id, name: 'Show $id', numberOfSeasons: 1);
          },
          fetchSeason: (id, season) async => const [],
        );
        expect(peak, 3);
      },
    );

    test(
      'a show whose seasons all fail is reported, not silently empty',
      () async {
        final data = await buildCalendar(
          showIds: [1],
          today: today,
          fetchShow: (id) async =>
              Show(id: 1, name: 'Silo', numberOfSeasons: 2),
          fetchSeason: (id, season) async => throw Exception('timed out'),
        );
        expect(data.failures, hasLength(1));
      },
    );
  });

  group('calendar labels', () {
    test('are dates, never times — and an aired episode never reads '
        'scheduled', () {
      expect(
        calendarTimingLabel(
          _cal(today.subtract(const Duration(days: 3))),
          today,
        ),
        'Aired',
      );
      expect(
        calendarTimingLabel(
          _cal(today.subtract(const Duration(days: 1))),
          today,
        ),
        'Aired yesterday',
      );
      expect(calendarTimingLabel(_cal(today), today), 'Airs today');
      expect(
        calendarTimingLabel(_cal(today.add(const Duration(days: 1))), today),
        'Tomorrow',
      );
      expect(
        calendarTimingLabel(_cal(today.add(const Duration(days: 5))), today),
        'In 5 days',
      );
    });

    test('count calendar days, so late evening does not make tomorrow '
        'today', () {
      final lateEvening = DateTime(2026, 10, 3, 23, 30);
      final tomorrow = _cal(DateTime(2026, 10, 4));
      expect(calendarTimingLabel(tomorrow, lateEvening), 'Tomorrow');
      expect(tomorrow.isUnairedOn(lateEvening), isTrue);
      expect(_cal(today).isUnairedOn(lateEvening), isFalse);
    });

    test('the header range matches the seven days the strip shows', () {
      expect(calendarRangeLabel(today), 'October 3 – 9, 2026');
      expect(calendarRangeLabel(DateTime(2026, 9, 29)), 'Sep 29 – Oct 5, 2026');
    });

    test('TMDB air dates parse as a calendar date', () {
      expect(calendarDateOf('2026-10-03'), DateTime(2026, 10, 3));
      expect(calendarDateOf(''), isNull);
      expect(calendarDateOf(null), isNull);
    });
  });

  test('the chip gradient wraps its second hue round the wheel', () {
    // `hue + 30 % 360` is `hue + 30`; at 340 that handed HSL a hue of 370.
    for (final hue in [0.0, 200.0, 335.0, 340.0, 359.0]) {
      final colors = calendarChipGradient(hue);
      final second = HSLColor.fromColor(colors[1]).hue;
      expect(second, closeTo((hue + 30) % 360, 1.5));
    }
  });

  group('CalendarScreen empty states', () {
    Future<void> pump(WidgetTester tester, CalendarData data) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            calendarEpisodesProvider.overrideWith((ref) async => data),
          ],
          child: const MaterialApp(home: Scaffold(body: CalendarScreen())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('no favourite shows says so, and offers a way to some', (
      tester,
    ) async {
      await pump(tester, const CalendarData(byDay: {}, showCount: 0));
      expect(find.text('No favorite shows yet'), findsOneWidget);
      expect(find.text('Browse shows'), findsOneWidget);
    });

    testWidgets('favourites with nothing coming up say exactly that, with '
        'the next known date', (tester) async {
      final next = CalendarEpisode(
        showId: 1,
        showName: 'Silo',
        seasonNumber: 3,
        episodeNumber: 1,
        airDate: DateTime.now().add(const Duration(days: 90)),
      );
      await pump(
        tester,
        CalendarData(byDay: const {}, showCount: 4, nextAfterWindow: next),
      );
      expect(
        find.text('Nothing airing in the next 30 days from your 4 shows.'),
        findsOneWidget,
      );
      expect(find.textContaining('Next up: Silo S03E01'), findsOneWidget);
      expect(find.textContaining('Add shows to your favorites'), findsNothing);
    });

    testWidgets('every show failing reads as an error with Try again', (
      tester,
    ) async {
      await pump(
        tester,
        CalendarData(
          byDay: const {},
          showCount: 2,
          failures: [
            CalendarShowFailure(
              showId: 1,
              error: Exception('Failed host lookup'),
            ),
            CalendarShowFailure(
              showId: 2,
              error: Exception('Failed host lookup'),
            ),
          ],
        ),
      );
      expect(find.text("Couldn't load your calendar"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining('favorites'), findsNothing);
    });

    testWidgets('some shows failing is said above the rest', (tester) async {
      await pump(
        tester,
        CalendarData(
          byDay: const {},
          showCount: 4,
          failures: [
            CalendarShowFailure(showId: 1, error: Exception('timed out')),
          ],
        ),
      );
      expect(
        find.textContaining("Couldn't load 1 of your 4 shows"),
        findsOneWidget,
      );
    });
  });
}
