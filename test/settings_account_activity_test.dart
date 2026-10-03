import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/models/auto_download_event.dart';
import 'package:mediahub/providers/auto_download_events_provider.dart';
import 'package:mediahub/providers/favorites_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/tmdb_account_provider.dart';
import 'package:mediahub/providers/tmdb_synced_ids.dart';
import 'package:mediahub/providers/watchlist_provider.dart';
import 'package:mediahub/screens/settings/auto_download_activity.dart';
import 'package:mediahub/services/tmdb_account_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/widgets/tmdb_account_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Events extends AutoDownloadEventsNotifier {
  _Events(this.events);
  final List<AutoDownloadEvent> events;

  @override
  List<AutoDownloadEvent> build() {
    super.build(); // sets up the store "Clear" writes to
    return events;
  }
}

AutoDownloadEvent _event(
  String show,
  int episode,
  AutoDownloadEventType type, {
  int minutesAgo = 0,
}) => AutoDownloadEvent(
  timestamp: DateTime.now().subtract(Duration(minutes: minutesAgo)),
  type: type,
  showId: show.hashCode,
  showName: show,
  season: 1,
  episode: episode,
  quality: '1080p',
);

/// Signed in, without the Keychain or the network.
class _SignedIn extends TmdbSessionNotifier {
  @override
  TmdbSession? build() => TmdbSession(
    accessToken: 'user-token',
    accountId: 7,
    account: TmdbAccount(id: 7, username: 'moka'),
  );
}

/// Signed out; sign-in requests are counted instead of opening a browser.
class _SignedOut extends TmdbSessionNotifier {
  int requests = 0;

  @override
  TmdbSession? build() => null;

  @override
  Future<String> beginSignIn() async => 'request-${++requests}';

  @override
  Future<void> completeSignIn(String approvedRequestToken) async =>
      throw TmdbApiException('not approved', statusCode: 401);
}

class _Favorites extends FavoritesNotifier {
  _Favorites(this.result);
  final TmdbSyncResult result;

  @override
  Future<TmdbSyncResult> syncFromTmdb({bool pushLocalFirst = false}) async =>
      result;
}

class _Watchlist extends WatchlistNotifier {
  _Watchlist(this.result);
  final TmdbSyncResult result;

  @override
  Future<TmdbSyncResult> syncFromTmdb({bool pushLocalFirst = false}) async =>
      result;
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ...overrides,
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  group('recent auto-download activity', () {
    testWidgets('says so when there is nothing yet', (tester) async {
      await pump(
        tester,
        const AutoDownloadActivity(),
        overrides: [autoDownloadEventsProvider.overrideWith(() => _Events([]))],
      );
      expect(find.textContaining('Nothing yet'), findsOneWidget);
    });

    testWidgets('lists newest first, in plain words', (tester) async {
      await pump(
        tester,
        const AutoDownloadActivity(),
        overrides: [
          autoDownloadEventsProvider.overrideWith(
            () => _Events([
              _event('Severance', 3, AutoDownloadEventType.downloadStarted),
              _event(
                'Andor',
                2,
                AutoDownloadEventType.torrentNotFound,
                minutesAgo: 90,
              ),
            ]),
          ),
        ],
      );
      final newer = tester.getTopLeft(find.text('Severance S01E03'));
      final older = tester.getTopLeft(find.text('Andor S01E02'));
      expect(newer.dy, lessThan(older.dy));
      expect(find.text('Download started · 1080p'), findsOneWidget);
      expect(find.text('No source found yet · 1080p'), findsOneWidget);
      expect(find.text('1 hour ago'), findsOneWidget);
    });

    testWidgets('shows five, then all on request, and can be cleared', (
      tester,
    ) async {
      final events = [
        for (var i = 1; i <= 8; i++)
          _event('Show', i, AutoDownloadEventType.downloadCompleted),
      ];
      await pump(
        tester,
        const AutoDownloadActivity(),
        overrides: [
          autoDownloadEventsProvider.overrideWith(() => _Events(events)),
        ],
      );
      expect(find.textContaining('Show S01E'), findsNWidgets(5));
      await tester.tap(find.text('Show all (8)'));
      await tester.pump();
      expect(find.textContaining('Show S01E'), findsNWidgets(8));

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(find.textContaining('Nothing yet'), findsOneWidget);
    });
  });

  group('TMDB account', () {
    List<Override> signedIn(TmdbSyncResult result) => [
      hasTmdbApiKeyProvider.overrideWithValue(true),
      tmdbSessionProvider.overrideWith(_SignedIn.new),
      favoritesProvider.overrideWith(() => _Favorites(result)),
      watchlistProvider.overrideWith(() => _Watchlist(result)),
      // No watched-state reconcile: it needs the network.
      tmdbWatchedSyncProvider.overrideWithValue(null),
    ];

    testWidgets('"synced" only after a sync that worked', (tester) async {
      await pump(
        tester,
        const TmdbAccountSection(),
        overrides: signedIn(const TmdbSyncResult(TmdbSyncOutcome.synced)),
      );
      expect(find.text('Signed in as moka'), findsOneWidget);
      // It used to print "(synced)" before anything had been synced.
      expect(find.textContaining('synced at'), findsNothing);

      await tester.tap(find.text('Sync now'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('synced at'), findsOneWidget);
    });

    testWidgets('a failed sync says so, in plain words', (tester) async {
      await pump(
        tester,
        const TmdbAccountSection(),
        overrides: signedIn(
          const TmdbSyncResult(
            TmdbSyncOutcome.failed,
            pendingChanges: 2,
            error: SocketException('Failed host lookup'),
          ),
        ),
      );
      await tester.tap(find.text('Sync now'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('synced at'), findsNothing);
      expect(find.textContaining('Couldn\'t sync with TMDB'), findsOneWidget);
      expect(
        find.textContaining('Couldn\'t reach the internet'),
        findsOneWidget,
      );
      expect(
        find.textContaining('changes waiting to reach TMDB'),
        findsOneWidget,
      );
      expect(find.textContaining('SocketException'), findsNothing);
    });

    testWidgets('a sign-in that failed to finish can start over', (
      tester,
    ) async {
      final session = _SignedOut();
      await pump(
        tester,
        const TmdbAccountSection(),
        overrides: [
          hasTmdbApiKeyProvider.overrideWithValue(true),
          tmdbSessionProvider.overrideWith(() => session),
        ],
      );
      await tester.tap(find.text('Sign in with TMDB'));
      await tester.pump();
      await tester.pump();
      expect(session.requests, 1);

      await tester.tap(find.text('Finish sign-in'));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('didn\'t confirm the sign-in'),
        findsOneWidget,
      );

      // The only way out used to be leaving Settings.
      await tester.tap(find.text('Start over'));
      await tester.pump();
      await tester.pump();
      expect(session.requests, 2);
      expect(find.textContaining('didn\'t confirm the sign-in'), findsNothing);
      expect(find.text('Finish sign-in'), findsOneWidget);
    });
  });
}
