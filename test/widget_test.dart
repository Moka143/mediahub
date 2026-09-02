import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/app.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A boot smoke test for the root widget.
///
/// This file used to assert `expect(true, isTrue)` behind a note saying a real
/// test would need SharedPreferences mocked. It does not: the store is
/// injected through `sharedPreferencesProvider`, so a mock and an override are
/// the whole setup. In the meantime the placeholder counted as a passing test
/// while covering nothing, which is worse than no test at all.
///
/// What this catches is narrow but real — the app's theme and root scaffolding
/// building without throwing, which nothing else in the suite exercises.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The theme resolves its faces through google_fonts, which reaches out to
  // fonts.gstatic.com on a miss. Pin the bundled fallback so this stays a
  // build test: CI should not be able to fail it by being offline.
  GoogleFonts.config.allowRuntimeFetching = false;

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Widget booted() => ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: const MediaHubApp(),
  );

  testWidgets('the root widget builds without throwing', (tester) async {
    await tester.pumpWidget(booted());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ships dark-only, regardless of platform brightness', (
    tester,
  ) async {
    await tester.pumpWidget(booted());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(
      app.darkTheme?.brightness,
      Brightness.dark,
      reason: 'the editorial palette has no light variant',
    );
  });

  testWidgets('exposes the global messenger and navigator keys', (
    tester,
  ) async {
    await tester.pumpWidget(booted());

    // These are how services show a snackbar or navigate from outside the
    // tree; a null key here means those paths silently do nothing.
    expect(rootScaffoldMessengerKey.currentState, isNotNull);
    expect(rootNavigatorKey.currentState, isNotNull);
  });

  testWidgets('titles the window with the app name', (tester) async {
    await tester.pumpWidget(booted());

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, AppConstants.appName);
  });
}
