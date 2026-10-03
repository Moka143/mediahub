import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/window_fit_service.dart';

void main() {
  group('WindowFitService.shrinkToFit', () {
    // A 1920x1032 work area (1080p minus the taskbar) at 100%.
    const workArea = Rect.fromLTWH(0, 0, 1920, 1032);
    final windowsSlack = WindowFitService.frameSlack(windows: true, scale: 1);

    test('leaves a window that fits alone', () {
      expect(
        WindowFitService.shrinkToFit(
          window: const Rect.fromLTWH(100, 100, 1200, 800),
          workAreas: const [workArea],
          slack: windowsSlack,
        ),
        isNull,
      );
    });

    test('a snapped window measuring its invisible borders is not resized', () {
      // GetWindowRect includes ~7 px of invisible border left, right and
      // bottom: a window snapped to fill the work area measures wider than
      // it. This used to shrink every snapped window, fighting the user.
      expect(
        WindowFitService.shrinkToFit(
          window: const Rect.fromLTWH(-7, 0, 1934, 1039),
          workAreas: const [workArea],
          slack: windowsSlack,
        ),
        isNull,
      );
    });

    test('the allowance scales with the display', () {
      final slack = WindowFitService.frameSlack(windows: true, scale: 2.5);
      expect(slack, greaterThan(windowsSlack));
      expect(
        WindowFitService.shrinkToFit(
          window: const Rect.fromLTWH(-18, 0, 1956, 1050),
          workAreas: const [workArea],
          slack: slack,
        ),
        isNull,
      );
    });

    test('a window genuinely too big for its display is shrunk', () {
      // Dragged from a roomy monitor onto a small one.
      expect(
        WindowFitService.shrinkToFit(
          window: const Rect.fromLTWH(0, 0, 2400, 1400),
          workAreas: const [workArea],
          slack: windowsSlack,
        ),
        const Size(1920, 1032),
      );
    });

    test('only the dimension that does not fit changes', () {
      expect(
        WindowFitService.shrinkToFit(
          window: const Rect.fromLTWH(0, 0, 1000, 1400),
          workAreas: const [workArea],
          slack: windowsSlack,
        ),
        const Size(1000, 1032),
      );
    });

    test('judges against the display the window mostly sits on', () {
      const second = Rect.fromLTWH(1920, 0, 1280, 720);
      expect(
        WindowFitService.shrinkToFit(
          window: const Rect.fromLTWH(2000, 0, 1600, 700),
          workAreas: const [workArea, second],
          slack: windowsSlack,
        ),
        const Size(1280, 700),
      );
    });

    test('macOS gets no border allowance — it has no invisible frame', () {
      expect(WindowFitService.frameSlack(windows: false, scale: 2), 1);
    });

    test('no displays reported, no opinion', () {
      expect(
        WindowFitService.shrinkToFit(
          window: const Rect.fromLTWH(0, 0, 5000, 5000),
          workAreas: const [],
          slack: 1,
        ),
        isNull,
      );
    });
  });
}
