import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/screens/onboarding_screen.dart';
import 'package:mediahub/screens/settings/tmdb_token_check.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for TMDB: answers the trending request the way TMDB would for
/// [accepted] tokens, and fails every other one with [failure].
class _FakeTmdb extends TmdbApiService {
  _FakeTmdb(String token, this.accepted, this.failure, this.calls)
    : super(accessToken: token);

  final Set<String> accepted;
  final Object failure;
  final List<String> calls;

  @override
  Future<List<Show>> getTrendingShows({
    String timeWindow = 'week',
    int page = 1,
  }) async {
    calls.add(accessToken);
    if (accepted.contains(accessToken)) return const [];
    throw failure;
  }
}

const _good = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJnb29kIn0.c2lnbmF0dXJl';
const _bad = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJiYWQifQ.c2lnbmF0dXJl';

/// What TmdbApiService throws when TMDB answers 401: its own exception,
/// carrying the status `classifyFailure` reads.
final _unauthorized = TmdbApiException(
  'Failed to get trending shows: TMDB answered 401',
  statusCode: 401,
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SharedPreferences prefs;
  late List<String> calls;

  Future<ProviderContainer> boot(WidgetTester tester, {Object? failure}) async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    calls = [];
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          tmdbTokenCheckServiceProvider.overrideWithValue(
            (token) =>
                _FakeTmdb(token, {_good}, failure ?? _unauthorized, calls),
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const OnboardingScreen(),
        ),
      ),
    );
    await tester.pump();
    return ProviderScope.containerOf(
      tester.element(find.byType(OnboardingScreen)),
    );
  }

  Future<void> paste(WidgetTester tester, String token) async {
    await tester.enterText(find.byType(TextField), token);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a token TMDB rejects is not saved, and says why', (
    tester,
  ) async {
    final container = await boot(tester);
    expect(find.text('Paste your TMDB token'), findsOneWidget);

    await paste(tester, _bad);

    expect(calls, [_bad], reason: 'checked with TMDB before saving');
    expect(container.read(settingsProvider).tmdbApiKey, isEmpty);
    expect(
      find.textContaining('TMDB didn\'t accept this token'),
      findsOneWidget,
    );
    // Still on step 1 — a bad paste used to land on a Home that quietly
    // failed to load anything.
    expect(find.text('Paste your TMDB token'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
  });

  testWidgets('a token TMDB accepts is saved and moves on', (tester) async {
    final container = await boot(tester);
    await paste(tester, _good);

    expect(container.read(settingsProvider).tmdbApiKey, _good);
    expect(find.text('Token saved.'), findsOneWidget);
    expect(find.text('Sign in with TMDB'), findsOneWidget);
  });

  testWidgets('something that is not a token never reaches TMDB', (
    tester,
  ) async {
    final container = await boot(tester);
    await paste(tester, '0123456789abcdef0123456789abcdef');

    expect(calls, isEmpty);
    expect(container.read(settingsProvider).tmdbApiKey, isEmpty);
    expect(find.textContaining('starts with eyJ'), findsWidgets);
  });

  testWidgets('offline: explains, and offers to continue unchecked', (
    tester,
  ) async {
    final container = await boot(
      tester,
      failure: const SocketException('Failed host lookup'),
    );
    await paste(tester, _bad);

    expect(container.read(settingsProvider).tmdbApiKey, isEmpty);
    expect(find.textContaining('Couldn\'t reach the internet'), findsOneWidget);

    await tester.tap(find.text('Continue without checking'));
    await tester.pump();
    expect(container.read(settingsProvider).tmdbApiKey, _bad);
    expect(find.text('Token saved.'), findsOneWidget);
  });
}
