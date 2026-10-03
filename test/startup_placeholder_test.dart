import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/app.dart';

void main() {
  testWidgets('says why it is waiting once the wait is no longer short', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(const StartupPlaceholder());
      expect(find.text('MediaHub'), findsOneWidget);
      expect(find.textContaining('keychain'), findsNothing);

      await tester.pump(StartupPlaceholder.hintDelay);
      expect(find.textContaining('allow MediaHub'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows gets a plain loading line', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(const StartupPlaceholder());
      await tester.pump(StartupPlaceholder.hintDelay);
      expect(find.text('Loading your saved credentials…'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
