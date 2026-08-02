import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_torrent_client/services/window_state_service.dart';

void main() {
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
}
