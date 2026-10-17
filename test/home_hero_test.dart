import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/screens/home/home_hero.dart';

void main() {
  testWidgets('a two-line title over a long overview keeps its buttons', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final show = Show(
      id: 1,
      name: 'A Show With A Title Long Enough To Wrap',
      overview: List.filled(40, 'An overview that runs on.').join(' '),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                HeroCard(
                  progress: null,
                  art: null,
                  fallbackShow: show,
                  onPrimaryTap: () {},
                  onSecondaryTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // A fixed height overflowed here; a minimum grows to fit instead.
    expect(tester.takeException(), isNull);
    final card = tester.getRect(find.byType(HeroCard));
    expect(card.height, greaterThan(360));
    for (final label in ['Stream', 'Details']) {
      final button = tester.getRect(find.text(label));
      expect(card.contains(button.bottomRight), isTrue, reason: label);
    }
  });

  testWidgets('a short hero keeps its 360 px height', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                HeroCard(
                  progress: null,
                  art: null,
                  fallbackShow: null,
                  onPrimaryTap: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(HeroCard)).height, 360);
  });
}
