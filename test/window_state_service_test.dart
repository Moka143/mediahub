import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/services/window_state_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('WindowStateService.isOnScreen', () {
    // A laptop screen with a second monitor to its right.
    const laptop = Rect.fromLTWH(0, 0, 1920, 1040);
    const external = Rect.fromLTWH(1920, 0, 2560, 1400);

    test('accepts a window sitting on the primary display', () {
      expect(
        WindowStateService.isOnScreen(const Rect.fromLTWH(100, 80, 1280, 800), [
          laptop,
        ]),
        isTrue,
      );
    });

    test('accepts a window on a secondary display', () {
      expect(
        WindowStateService.isOnScreen(
          const Rect.fromLTWH(2200, 200, 1280, 800),
          [laptop, external],
        ),
        isTrue,
      );
    });

    test('rejects that same window once the display is unplugged', () {
      expect(
        WindowStateService.isOnScreen(
          const Rect.fromLTWH(2200, 200, 1280, 800),
          [laptop],
        ),
        isFalse,
      );
    });

    test('accepts a window straddling two displays', () {
      expect(
        WindowStateService.isOnScreen(
          const Rect.fromLTWH(1600, 100, 1280, 800),
          [laptop, external],
        ),
        isTrue,
      );
    });

    test('rejects a sliver too narrow to grab', () {
      // Ten pixels of window peeking past the left edge is not reachable.
      expect(
        WindowStateService.isOnScreen(
          const Rect.fromLTWH(-1270, 100, 1280, 800),
          [laptop],
        ),
        isFalse,
      );
    });

    test('rejects a window above the top edge', () {
      expect(
        WindowStateService.isOnScreen(
          const Rect.fromLTWH(100, -780, 1280, 800),
          [laptop],
        ),
        isFalse,
      );
    });

    test('accepts a window overlapping by exactly the minimum', () {
      expect(
        WindowStateService.isOnScreen(
          Rect.fromLTWH(
            1920 - WindowStateService.minVisibleExtent,
            0,
            1280,
            800,
          ),
          [laptop],
        ),
        isTrue,
      );
    });

    test('rejects everything when no displays are reported', () {
      expect(
        WindowStateService.isOnScreen(
          const Rect.fromLTWH(100, 80, 1280, 800),
          const [],
        ),
        isFalse,
      );
    });
  });

  group('WindowStateService.fitToWorkArea', () {
    const minimum = Size(800, 600);

    test('leaves a window that already fits alone', () {
      expect(
        WindowStateService.fitToWorkArea(
          const Size(1100, 720),
          const Size(1920, 1040),
          minimum,
        ),
        const Size(1100, 720),
      );
    });

    test('shrinks to the work area on a 720p screen', () {
      // 1280x720 with a taskbar: the 720-tall default does not fit, and
      // centring it put the title bar above the top of the screen.
      expect(
        WindowStateService.fitToWorkArea(
          const Size(1100, 720),
          const Size(1280, 672),
          minimum,
        ),
        const Size(1100, 672),
      );
    });

    test('never shrinks below the minimum window size', () {
      expect(
        WindowStateService.fitToWorkArea(
          const Size(1100, 720),
          const Size(640, 480),
          minimum,
        ),
        minimum,
      );
    });
  });

  group('WindowStateService.isSane', () {
    test('accepts an ordinary window rectangle', () {
      expect(
        WindowStateService.isSane(const Rect.fromLTWH(100, 80, 1280, 800)),
        isTrue,
      );
    });

    test(
      'rejects the all-zero rectangle a corrupt prefs file deserialises to',
      () {
        expect(WindowStateService.isSane(Rect.zero), isFalse);
      },
    );

    test('rejects rectangles too small to host a usable window', () {
      expect(
        WindowStateService.isSane(const Rect.fromLTWH(0, 0, 199, 400)),
        isFalse,
      );
      expect(
        WindowStateService.isSane(const Rect.fromLTWH(0, 0, 400, 199)),
        isFalse,
      );
    });

    test('accepts exactly the minimum dimensions', () {
      expect(
        WindowStateService.isSane(const Rect.fromLTWH(0, 0, 200, 200)),
        isTrue,
      );
    });

    test('rejects non-finite coordinates', () {
      expect(
        WindowStateService.isSane(const Rect.fromLTWH(double.nan, 0, 400, 400)),
        isFalse,
      );
      expect(
        WindowStateService.isSane(
          const Rect.fromLTWH(0, double.infinity, 400, 400),
        ),
        isFalse,
      );
      expect(
        WindowStateService.isSane(const Rect.fromLTWH(0, 0, double.nan, 400)),
        isFalse,
      );
      expect(
        WindowStateService.isSane(
          const Rect.fromLTWH(0, 0, 400, double.infinity),
        ),
        isFalse,
      );
    });

    test(
      'allows negative origins for monitors left of or above the primary',
      () {
        expect(
          WindowStateService.isSane(
            const Rect.fromLTWH(-1920, -200, 1280, 800),
          ),
          isTrue,
        );
      },
    );
  });

  group('WindowStateService close handling', () {
    // `main` sets setPreventClose(true) so the close-time save has somewhere
    // to run — which means this service is now the only thing that closes the
    // window. If it ever failed to, the app would be unquittable, so this is
    // the property that matters more than the saving.
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('always closes, even when saving throws', () async {
      // There is no window_manager plugin behind a unit test, so saveNow()
      // throws MissingPluginException on its first call — standing in for
      // any real failure: a locked prefs file, a full disk, a native call
      // that never answers.
      final prefs = await SharedPreferences.getInstance();
      var closed = false;
      final service = WindowStateService(
        prefs,
        onClosed: () async => closed = true,
      );

      service.onWindowClose();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(closed, isTrue, reason: 'a failed save must not trap the user');
    });

    test('closes exactly once', () async {
      final prefs = await SharedPreferences.getInstance();
      var closeCount = 0;
      final service = WindowStateService(
        prefs,
        onClosed: () async => closeCount++,
      );

      service.onWindowClose();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(closeCount, 1);
    });
  });
}
