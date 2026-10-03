import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/navigation_provider.dart';
import 'package:mediahub/utils/error_messages.dart';
import 'package:mediahub/utils/formatters.dart';
import 'package:mediahub/utils/media_names.dart';
import 'package:mediahub/widgets/common/browse_pagination_footer.dart';
import 'package:mediahub/widgets/common/hub_pressable.dart';

void main() {
  group('parseEpisodeCode', () {
    test('reads the common forms', () {
      expect(parseEpisodeCode('Show.S01E05.1080p.mkv'), (
        season: 1,
        episode: 5,
      ));
      expect(parseEpisodeCode('show s2e7 720p'), (season: 2, episode: 7));
      expect(parseEpisodeCode('Show.S03.E04.mkv'), (season: 3, episode: 4));
      expect(parseEpisodeCode('Show 1x05 HDTV'), (season: 1, episode: 5));
      expect(parseEpisodeCode('Show Season 2 Episode 10'), (
        season: 2,
        episode: 10,
      ));
    });

    test('keeps three-digit episodes whole', () {
      expect(parseEpisodeCode('One.Piece.S01E105.mkv'), (
        season: 1,
        episode: 105,
      ));
      expect(parseEpisodeCode('Show 1x123'), (season: 1, episode: 123));
    });

    test('does not read a resolution or codec as an episode', () {
      expect(parseEpisodeCode('Movie.1920x1080.x264.mkv'), isNull);
      expect(parseEpisodeCode('Movie.2019.1080p.mkv'), isNull);
    });

    test('nameHasEpisode is exact, not a prefix', () {
      expect(nameHasEpisode('Show.S01E10.mkv', 1, 1), isFalse);
      expect(nameHasEpisode('Show.S01E01.mkv', 1, 10), isFalse);
      expect(nameHasEpisode('Show.S02E30.mkv', 2, 3), isFalse);
      expect(nameHasEpisode('Show.S02E03.mkv', 2, 3), isTrue);
    });
  });

  group('titlesMatch', () {
    test('ignores case, punctuation and a leading article', () {
      expect(titlesMatch('The Office', 'the.office'), isTrue);
      expect(titlesMatch("Grey's Anatomy", 'Greys Anatomy'), isTrue);
      expect(titlesMatch('Mr. Robot', 'Mr Robot'), isTrue);
      expect(titlesMatch('Law & Order', 'Law and Order'), isTrue);
    });

    test('never matches on containment', () {
      expect(titlesMatch('You', 'Young Sheldon'), isFalse);
      expect(titlesMatch('Dark', 'Dark Matter'), isFalse);
      expect(titlesMatch('Up', 'Upgrade'), isFalse);
      expect(titlesMatch('The Boys', 'Boys Over Flowers'), isFalse);
    });

    test('a year or country may be missing on one side, not differ', () {
      expect(titlesMatch('Doctor Who 2005', 'Doctor Who'), isTrue);
      expect(titlesMatch('Doctor Who 2005', 'Doctor Who 1963'), isFalse);
      expect(titlesMatch('The Office US', 'The Office'), isTrue);
      expect(titlesMatch('The Office US', 'The Office UK'), isFalse);
    });

    test('a title that is only a year is still a title', () {
      expect(titlesMatch('1923', '1923'), isTrue);
      expect(titlesMatch('1923', '1883'), isFalse);
    });

    test('empty and symbol-only titles match nothing', () {
      expect(titlesMatch('', ''), isFalse);
      expect(titlesMatch('...', 'Show'), isFalse);
    });

    test('non-Latin titles are compared, not erased', () {
      expect(titlesMatch('進撃の巨人', '進撃の巨人'), isTrue);
      expect(titlesMatch('進撃の巨人', 'Show'), isFalse);
    });
  });

  group('calendarDaysBetween', () {
    test('tomorrow is one day at any time of day', () {
      final evening = DateTime(2026, 10, 3, 22, 30);
      expect(Formatters.calendarDaysBetween(evening, DateTime(2026, 10, 4)), 1);
      expect(Formatters.calendarDaysBetween(evening, DateTime(2026, 10, 3)), 0);
      expect(
        Formatters.calendarDaysBetween(evening, DateTime(2026, 10, 2)),
        -1,
      );
    });

    test('counts calendar days across a long gap', () {
      expect(
        Formatters.calendarDaysBetween(
          DateTime(2026, 10, 3, 23),
          DateTime(2027, 7, 8),
        ),
        278,
      );
    });
  });

  group('friendlyErrorMessage', () {
    DioException dio(DioExceptionType type, {int? status}) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: type,
      response: status == null
          ? null
          : Response(
              requestOptions: RequestOptions(path: '/x'),
              statusCode: status,
            ),
    );

    test('classifies the common failures', () {
      expect(
        classifyFailure(dio(DioExceptionType.connectionError)),
        FailureKind.offline,
      );
      expect(
        classifyFailure(dio(DioExceptionType.receiveTimeout)),
        FailureKind.timeout,
      );
      expect(
        classifyFailure(dio(DioExceptionType.badResponse, status: 401)),
        FailureKind.unauthorized,
      );
      expect(
        classifyFailure(dio(DioExceptionType.badResponse, status: 503)),
        FailureKind.serviceDown,
      );
      expect(
        classifyFailure(const SocketException('no route')),
        FailureKind.offline,
      );
    });

    test('reads wrapped exception text', () {
      final wrapped = Exception(
        'TmdbApiException: Failed to get trending shows: DioException '
        '[bad response]: This exception was thrown because the response has '
        'a status code of 401',
      );
      expect(classifyFailure(wrapped), FailureKind.unauthorized);
      expect(failureNeedsSettings(wrapped), isTrue);
    });

    test('never shows the raw exception', () {
      final message = friendlyErrorMessage(
        Exception('TmdbApiException: boom DioException'),
        subject: 'shows',
      );
      expect(message, isNot(contains('Exception')));
      expect(message, contains('shows'));
    });
  });

  group('AppTab', () {
    test('indices follow the sidebar order', () {
      expect(AppTab.home.index, 0);
      expect(AppTab.transfers.index, 1);
      expect(AppTab.shows.index, 2);
      expect(AppTab.movies.index, 3);
      expect(AppTab.library.index, 4);
      expect(AppTab.calendar.index, 5);
      expect(AppTab.favorites.index, 6);
    });
  });

  group('HubPressable', () {
    testWidgets('activates from the keyboard and is a button', (tester) async {
      var taps = 0;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: HubPressable(
              autofocus: true,
              tooltip: 'Do it',
              onTap: () => taps++,
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(taps, 2);

      await tester.tap(find.byType(HubPressable));
      expect(taps, 3);

      expect(
        tester.getSemantics(find.bySemanticsLabel('Do it')),
        isSemantics(
          isButton: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('without a handler it is not focusable', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: HubPressable(child: SizedBox(width: 40, height: 40)),
          ),
        ),
      );
      final focus = tester.widget<Focus>(
        find
            .descendant(
              of: find.byType(HubPressable),
              matching: find.byType(Focus),
            )
            .first,
      );
      expect(focus.canRequestFocus, isFalse);
    });
  });

  group('BrowsePaginationFooter', () {
    testWidgets('shows a retry when a later page fails', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowsePaginationFooter(
              loading: false,
              exhausted: false,
              hasItems: true,
              error: Exception('x'),
              onRetry: () => retried = true,
            ),
          ),
        ),
      );
      expect(find.text("Couldn't load more."), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retried, isTrue);
    });
  });
}
