import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/widgets/media/media_poster_card.dart';

/// Build a context with a given text scale so the calculator can be probed
/// the way a real row would use it.
Future<double> _heightAt(
  WidgetTester tester, {
  double width = 152,
  bool hasSubtitle = true,
  double textScale = 1.0,
}) async {
  late double result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Builder(
        builder: (context) {
          result = MediaPosterCard.heightForWidth(
            context,
            width: width,
            hasSubtitle: hasSubtitle,
          );
          return const SizedBox();
        },
      ),
    ),
  );
  return result;
}

void main() {
  group('MediaPosterCard.heightForWidth', () {
    testWidgets('leaves room for the 2:3 poster plus the text block', (
      tester,
    ) async {
      final height = await _heightAt(tester);
      // Poster alone is 152 * 1.5 = 228; the rest is padding + two text
      // lines. The Continue Watching row used to hard-code 190, which
      // clipped 84 px off every card.
      expect(height, greaterThan(228));
      expect(height, greaterThan(190 + 84));
      // Sanity ceiling — if this ever balloons, the layout changed.
      expect(height, lessThan(300));
    });

    testWidgets('scales with the card width', (tester) async {
      final narrow = await _heightAt(tester, width: 120);
      final wide = await _heightAt(tester, width: 200);
      expect(wide, greaterThan(narrow));
      // The poster is the dominant term: +80 width ⇒ +120 poster height.
      expect(wide - narrow, closeTo(120, 1));
    });

    testWidgets('reserves less when there is no subtitle', (tester) async {
      final with_ = await _heightAt(tester);
      final without = await _heightAt(tester, hasSubtitle: false);
      expect(without, lessThan(with_));
    });

    testWidgets('grows with accessibility text scaling', (tester) async {
      // A fixed height would clip here; the whole point of measuring
      // through the TextScaler is that large-text users get a row that
      // still fits.
      final normal = await _heightAt(tester);
      final large = await _heightAt(tester, textScale: 2.0);
      expect(large, greaterThan(normal));
    });

    testWidgets('is a whole number of pixels', (tester) async {
      // Sub-pixel remainders are exactly how a 0.4 px overflow warning
      // appears out of nowhere.
      final height = await _heightAt(tester);
      expect(height, height.roundToDouble());
    });
  });

  group('MediaPosterCard caption', () {
    // The arithmetic above only matters if it describes the card that is
    // drawn: lay the real card out at exactly the height it asks for, and
    // any shortfall shows up as an overflow.
    for (final width in [120.0, 152.0, 180.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('fits at ${width.toInt()}px and ${scale}x text', (
          tester,
        ) async {
          await tester.pumpWidget(
            MaterialApp(
              // Inside the app: MaterialApp sets its own MediaQuery.
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      height: MediaPosterCard.heightForWidth(
                        context,
                        width: width,
                      ),
                      child: MediaPosterCard(
                        title: 'Arrival',
                        subtitle: '2.1 GB · 1080p',
                        width: width,
                        onTap: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('MediaPosterCard menu', () {
    Future<List<String>> pump(WidgetTester tester) async {
      final log = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MediaPosterCard(
                title: 'Arrival',
                onTap: () => log.add('open'),
                actions: [
                  MediaCardAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    onSelected: () => log.add('delete'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return log;
    }

    double menuOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.byIcon(Icons.more_vert_rounded),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;

    testWidgets('the keyboard reaches the card, and focus shows the menu', (
      tester,
    ) async {
      final log = await pump(tester);
      expect(menuOpacity(tester), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(menuOpacity(tester), 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(log, ['open']);
    });

    testWidgets('a right click opens the menu', (tester) async {
      final log = await pump(tester);
      await tester.tap(find.text('Arrival'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(log, ['delete']);
    });
  });
}
