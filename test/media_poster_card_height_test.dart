import 'package:flutter/material.dart';
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
}
