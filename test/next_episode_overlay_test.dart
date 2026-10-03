import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/widgets/common/hub_pressable.dart';
import 'package:mediahub/widgets/next_episode_overlay.dart';

/// The Up Next card's countdown.
void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  late int played;
  late int restored;

  setUp(() {
    played = 0;
    restored = 0;
  });

  Widget card({int? countdown, bool minimized = false}) => MaterialApp(
    theme: buildDarkTheme(),
    home: Scaffold(
      body: Center(
        child: NextEpisodeOverlay(
          episodeCode: 'S01E02',
          title: 'Severance',
          countdownSeconds: countdown,
          minimized: minimized,
          playLabel: countdown == null ? 'Stream' : 'Play',
          onPlay: () => played++,
          onMinimize: () {},
          onDismiss: () {},
          onRestore: () => restored++,
        ),
      ),
    ),
  );

  testWidgets('a countdown that arrives late still counts down and plays', (
    tester,
  ) async {
    // The card comes up for an episode TMDB knows about (Stream, no
    // countdown); its prefetch finishes during the credits and it becomes a
    // file on disk (Play, counting down). This used to sit on a frozen "0s".
    await tester.pumpWidget(card());
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(card(countdown: 10));
    expect(find.text('10S'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('6S'), findsOneWidget);
    expect(played, 0);

    await tester.pump(const Duration(seconds: 6));
    expect(played, 1);

    await tester.pump(const Duration(seconds: 3));
    expect(played, 1, reason: 'plays once');
  });

  testWidgets('restoring the card never plays on the spot', (tester) async {
    // Minimize → restore used to call onPlay from inside didUpdateWidget —
    // replacing the route in the middle of the parent's rebuild.
    await tester.pumpWidget(card());
    await tester.pumpWidget(card(minimized: true));
    await tester.pumpWidget(card(countdown: 10, minimized: true));
    await tester.pumpWidget(card(countdown: 10));
    expect(played, 0);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('7S'), findsOneWidget);
    expect(played, 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the countdown pauses while minimized', (tester) async {
    await tester.pumpWidget(card(countdown: 10));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(card(countdown: 10, minimized: true));
    await tester.pump(const Duration(seconds: 20));
    expect(played, 0);
    expect(find.text('8S'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the minimized chip is a real button', (tester) async {
    // It was a bare GestureDetector: no focus, no Enter, no button semantics.
    await tester.pumpWidget(card(countdown: 10, minimized: true));
    expect(find.byType(HubPressable), findsOneWidget);

    await tester.tap(find.byType(HubPressable));
    expect(restored, 1);

    final focus = tester
        .widget<FocusableActionDetector>(
          find.descendant(
            of: find.byType(HubPressable),
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .enabled;
    expect(focus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(restored, 2);

    await tester.pumpWidget(const SizedBox());
  });
}
