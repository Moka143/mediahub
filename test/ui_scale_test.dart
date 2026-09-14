import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/design/ui_scale.dart';

const _floor = Size(800, 600);

Widget _host(Size viewport, Widget child) => MediaQuery(
  data: MediaQueryData(size: viewport),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: UiScale(designFloor: _floor, child: child),
  ),
);

void main() {
  group('UiScale.scaleFor', () {
    test('leaves an ordinary desktop viewport alone', () {
      // 1920x1080 at 100%, and 1280x672 at 150% — the two cases the user was
      // worried this fix would shrink. Both must come back exactly 1.0.
      expect(UiScale.scaleFor(const Size(1920, 1032), _floor), 1.0);
      expect(UiScale.scaleFor(const Size(1280, 672), _floor), 1.0);
    });

    test('never scales up, however much room there is', () {
      expect(UiScale.scaleFor(const Size(3840, 2160), _floor), 1.0);
    });

    test('scales to fit a 1080p panel at 225%', () {
      // 1920x1080 / 2.25 = 853x480, less the taskbar. Height binds.
      expect(
        UiScale.scaleFor(const Size(853, 432), _floor),
        closeTo(432 / 600, 0.0001),
      );
    });

    test('the limiting dimension wins, not the average', () {
      // Wide and short: the width is fine, the height is not, and a scale
      // picked from the width would still clip the layout vertically.
      expect(
        UiScale.scaleFor(const Size(1600, 450), _floor),
        closeTo(450 / 600, 0.0001),
      );
    });

    test('clamps at minScale rather than vanishing', () {
      expect(UiScale.scaleFor(const Size(100, 80), _floor), UiScale.minScale);
    });

    test('treats a degenerate viewport as "no opinion"', () {
      // A zero-size viewport happens for a frame during startup and while the
      // window is minimised. Scaling by 0 or NaN would take the UI with it.
      expect(UiScale.scaleFor(Size.zero, _floor), 1.0);
      expect(UiScale.scaleFor(const Size(double.nan, 600), _floor), 1.0);
      expect(UiScale.scaleFor(const Size(double.infinity, 600), _floor), 1.0);
    });
  });

  group('UiScale widget', () {
    testWidgets('adds nothing to the tree at a normal viewport', (
      tester,
    ) async {
      // Load-bearing: the promise is that nothing changes on a normal screen,
      // and the cheapest way to keep that promise is to not be there at all.
      await tester.pumpWidget(
        _host(const Size(1920, 1032), const SizedBox.shrink()),
      );
      expect(find.byType(Transform), findsNothing);
    });

    testWidgets('hands the layout back a viewport it can fit in', (
      tester,
    ) async {
      late Size seen;
      await tester.pumpWidget(
        _host(
          const Size(853, 432),
          Builder(
            builder: (context) {
              seen = MediaQuery.sizeOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(find.byType(Transform), findsOneWidget);
      // 432/600 = 0.72 → an 1185x600 logical viewport, which clears both the
      // 800x600 design floor and the 900px sidebar gate.
      expect(seen.width, greaterThanOrEqualTo(_floor.width));
      expect(seen.height, greaterThanOrEqualTo(_floor.height - 0.01));
      expect(seen.width, greaterThan(900));
    });

    testWidgets('caps runaway accessibility text only when cramped', (
      tester,
    ) async {
      // Windows' "Make text bigger" is independent of display scale, so a
      // cramped viewport can arrive with 2.25x text on top. Capping it is a
      // last resort and must not touch a normal screen.
      late TextScaler cramped;
      late TextScaler roomy;

      Widget probe(void Function(TextScaler) sink) => Builder(
        builder: (context) {
          sink(MediaQuery.textScalerOf(context));
          return const SizedBox.shrink();
        },
      );

      Widget wrap(Size viewport, Widget child) => MediaQuery(
        data: MediaQueryData(
          size: viewport,
          textScaler: const TextScaler.linear(2.25),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: UiScale(designFloor: _floor, child: child),
        ),
      );

      await tester.pumpWidget(
        wrap(const Size(853, 432), probe((s) => cramped = s)),
      );
      await tester.pumpWidget(
        wrap(const Size(1920, 1032), probe((s) => roomy = s)),
      );

      expect(cramped.scale(10), lessThanOrEqualTo(13.0));
      expect(
        roomy.scale(10),
        22.5,
        reason: 'an accessibility preference is not a layout bug to override',
      );
    });

    testWidgets('clicks still land where they look', (tester) async {
      // Transform.scale inverse-maps pointer events, but it is the one thing
      // worth proving rather than trusting.
      var tapped = false;
      await tester.pumpWidget(
        _host(
          const Size(853, 432),
          Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              // opaque, because a bare SizedBox has nothing to hit — this is
              // about the transform, not about what absorbs the pointer.
              behavior: HitTestBehavior.opaque,
              onTap: () => tapped = true,
              child: const SizedBox(width: 200, height: 100),
            ),
          ),
        ),
      );

      // The box is 200x100 at the top-left of a viewport rendered at 0.72, so
      // it paints as 144x72 and its centre lands at (72, 36). Tapping the raw
      // screen coordinate proves the pointer is inverse-mapped through the
      // same transform the renderer painted with.
      expect(
        tester.getCenter(find.byType(GestureDetector)),
        const Offset(72, 36),
      );
      await tester.tapAt(const Offset(72, 36));
      expect(tapped, isTrue);
    });
  });
}
