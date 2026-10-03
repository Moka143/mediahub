import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/video.dart';
import 'package:mediahub/widgets/details/detail_shell.dart';

Video _video(String type, {bool official = true, String site = 'YouTube'}) =>
    Video(
      id: '$type-$official',
      key: 'abc123',
      name: type,
      site: site,
      type: type,
      official: official,
    );

void main() {
  group('bestTrailer', () {
    test('prefers an official trailer over everything else', () {
      final pick = bestTrailer([
        _video('Teaser'),
        _video('Trailer', official: false),
        _video('Trailer'),
      ]);
      expect(pick?.type, 'Trailer');
      expect(pick?.official, isTrue);
    });

    test('falls back to a teaser when there is no trailer', () {
      expect(bestTrailer([_video('Teaser')])?.type, 'Teaser');
    });

    test('an unofficial trailer still beats a teaser', () {
      final pick = bestTrailer([
        _video('Teaser'),
        _video('Trailer', official: false),
      ]);
      expect(pick?.type, 'Trailer');
    });

    test('ignores clips and featurettes — they are not the trailer', () {
      expect(bestTrailer([_video('Clip'), _video('Featurette')]), isNull);
    });

    test('ignores anything we cannot actually play', () {
      // No render path for Vimeo, so offering the button would be a dead end.
      expect(bestTrailer([_video('Trailer', site: 'Vimeo')]), isNull);
      expect(bestTrailer(const []), isNull);
    });
  });

  group('TrailerButton', () {
    testWidgets('renders nothing when there is no playable trailer', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TrailerButton(videos: [_video('Clip')])),
        ),
      );
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('counts the clips behind the button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrailerButton(videos: [_video('Trailer'), _video('Teaser')]),
          ),
        ),
      );
      expect(find.text('Trailer  ·  2'), findsOneWidget);
    });

    testWidgets('a lone trailer needs no count', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TrailerButton(videos: [_video('Trailer')])),
        ),
      );
      expect(find.text('Trailer'), findsOneWidget);
    });
  });

  group('FoldableSection', () {
    Widget host({bool expanded = false}) => MaterialApp(
      home: Scaffold(
        body: FoldableSection(
          title: 'Cast',
          count: '12 CREDITS',
          initiallyExpanded: expanded,
          child: const Text('the cast row'),
        ),
      ),
    );

    testWidgets('collapsed by default, but says what is behind it', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      expect(find.text('Cast'), findsOneWidget);
      expect(find.text('12 CREDITS'), findsOneWidget);
      expect(find.text('the cast row'), findsNothing);
    });

    testWidgets('the header toggles it', (tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.text('Cast'));
      await tester.pumpAndSettle();
      expect(find.text('the cast row'), findsOneWidget);

      await tester.tap(find.text('Cast'));
      await tester.pumpAndSettle();
      expect(find.text('the cast row'), findsNothing);
    });

    testWidgets('can start open', (tester) async {
      await tester.pumpWidget(host(expanded: true));
      expect(find.text('the cast row'), findsOneWidget);
    });
  });

  group('HoverScrollRow', () {
    testWidgets('is dimmed until the pointer arrives', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HoverScrollRow(
              height: 100,
              itemCount: 20,
              itemBuilder: (_, i) => SizedBox(width: 100, child: Text('$i')),
            ),
          ),
        ),
      );
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity).first,
      );
      expect(opacity.opacity, lessThan(1.0));
    });

    testWidgets('comes up to full strength while a card has keyboard focus', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HoverScrollRow(
              height: 100,
              itemCount: 5,
              itemBuilder: (_, i) => SizedBox(
                width: 100,
                child: TextButton(onPressed: () {}, child: Text('$i')),
              ),
            ),
          ),
        ),
      );
      double opacity() => tester
          .widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first)
          .opacity;
      expect(opacity(), lessThan(1.0));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(opacity(), 1.0);
    });

    testWidgets('the arrows stay hidden while it is at rest', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HoverScrollRow(
              height: 100,
              itemCount: 20,
              itemBuilder: (_, i) => SizedBox(width: 100, child: Text('$i')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Present in the tree but transparent and non-interactive, so they
      // cannot be clicked by accident.
      for (final icon in [
        Icons.chevron_left_rounded,
        Icons.chevron_right_rounded,
      ]) {
        final arrow = find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(AnimatedOpacity),
        );
        expect(tester.widget<AnimatedOpacity>(arrow.first).opacity, 0);
        expect(
          tester
              .widget<IgnorePointer>(
                find
                    .ancestor(
                      of: find.byIcon(icon),
                      matching: find.byType(IgnorePointer),
                    )
                    .first,
              )
              .ignoring,
          isTrue,
        );
      }
    });
  });
}
