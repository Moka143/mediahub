import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/screens/home/home_cards.dart';
import 'package:mediahub/screens/home/home_hero.dart';
import 'package:mediahub/widgets/media/poster_skeleton.dart';

Widget _at(double width, Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(child: child),
      ),
    ),
  ),
);

void main() {
  // Home's placeholders stand in while trending loads, so the hero does not
  // swap from "Welcome — Browse shows" to a show under the pointer, and the
  // rows do not pop in one by one.
  group('Home loading placeholders', () {
    for (final width in [480.0, 1400.0]) {
      testWidgets('the hero placeholder lays out at ${width.toInt()} px', (
        tester,
      ) async {
        await tester.pumpWidget(_at(width, const HeroSkeleton()));
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(HeroSkeleton)).height,
          greaterThanOrEqualTo(360),
        );
      });

      testWidgets('a row placeholder lays out at ${width.toInt()} px', (
        tester,
      ) async {
        await tester.pumpWidget(
          _at(width, const HomeRowSkeleton(title: 'Trending shows')),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('Trending shows'), findsOneWidget);
        expect(find.byType(PosterSkeleton), findsWidgets);
      });
    }
  });
}
