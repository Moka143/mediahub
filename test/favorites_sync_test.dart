import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/upcoming_episode.dart';
import 'package:mediahub/providers/favorites_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/providers/tmdb_account_provider.dart';
import 'package:mediahub/providers/tmdb_synced_ids.dart';
import 'package:mediahub/providers/watchlist_provider.dart';
import 'package:mediahub/services/tmdb_account_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Favorites and the watchlist, mirrored to the TMDB account.
///
/// They used to undo themselves: a push that failed was logged and
/// forgotten, and the launch sync then replaced the local list with the
/// server's — so a favorite added offline vanished at the next launch, and
/// nothing said why.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, _Account)> containerWith({
    bool signedIn = true,
    Map<String, Object> prefs = const {},
    _Account? account,
    _Catalogue? catalogue,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    final acct = account ?? _Account();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
        if (signedIn) tmdbSessionProvider.overrideWith(_SignedIn.new),
        tmdbAccountServiceProvider.overrideWithValue(acct),
        tmdbApiServiceProvider.overrideWithValue(catalogue ?? _Catalogue()),
      ],
    );
    addTearDown(c.dispose);
    for (final p in [favoritesProvider, watchlistProvider]) {
      final sub = c.listen(p, (_, _) {});
      addTearDown(sub.close);
    }
    return (c, acct);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  group('favorites', () {
    test('signed out: a toggle is local only', () async {
      final (c, account) = await containerWith(signedIn: false);
      await c.read(favoritesProvider.notifier).toggleFavorite(1);
      await settle();

      expect(c.read(favoritesProvider).favoriteIds, {1});
      expect(account.pushes, isEmpty);
      expect(c.read(favoritesProvider.notifier).pendingChanges, isEmpty);
    });

    test('a failed push is queued, kept and retried by the sync', () async {
      final account = _Account(failPushes: true);
      final (c, _) = await containerWith(account: account);
      final n = c.read(favoritesProvider.notifier);

      await n.toggleFavorite(1);
      await settle();
      expect(n.pendingChanges.single.id, 1);

      // The server does not have it yet — and must not take it away.
      var result = await n.syncFromTmdb();
      expect(result.outcome, TmdbSyncOutcome.synced);
      expect(result.pendingChanges, 1);
      expect(c.read(favoritesProvider).favoriteIds, {1});

      // Back online: the queued push goes through, and the queue empties.
      account.failPushes = false;
      account.remoteShows.add(1);
      result = await n.syncFromTmdb();
      expect(account.pushes, contains('fav tv:1 on'));
      expect(result.pendingChanges, 0);
      expect(n.pendingChanges, isEmpty);
    });

    test('the queue survives a restart', () async {
      final account = _Account(failPushes: true);
      final (c, _) = await containerWith(account: account);
      await c.read(favoritesProvider.notifier).toggleFavorite(9);
      await settle();

      final prefs = c.read(sharedPreferencesProvider);
      final again = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          tmdbSessionProvider.overrideWith(_SignedIn.new),
          tmdbAccountServiceProvider.overrideWithValue(account),
        ],
      );
      addTearDown(again.dispose);
      expect(
        again.read(favoritesProvider.notifier).pendingChanges.single.id,
        9,
      );
    });

    test('an un-favorite made offline is not undone by the sync', () async {
      final account = _Account(remoteShows: {1, 2});
      final (c, _) = await containerWith(account: account);
      final n = c.read(favoritesProvider.notifier);
      await n.syncFromTmdb();
      expect(c.read(favoritesProvider).favoriteIds, {1, 2});

      account.failPushes = true;
      await n.toggleFavorite(2);
      await settle();
      await n.syncFromTmdb();

      expect(c.read(favoritesProvider).favoriteIds, {1});
    });

    test('a sync that cannot reach TMDB says so and changes nothing', () async {
      final account = _Account(failReads: true);
      final (c, _) = await containerWith(
        account: account,
        prefs: {
          'favorite_shows': jsonEncode([5]),
        },
      );

      final result = await c.read(favoritesProvider.notifier).syncFromTmdb();

      expect(result.ok, isFalse);
      expect(result.outcome, TmdbSyncOutcome.failed);
      expect(result.message, isNot(contains('Exception')));
      expect(c.read(favoritesProvider).favoriteIds, {5});
      expect(c.read(favoritesProvider).error, isNotNull);
      expect(c.read(favoritesProvider).isSyncing, isFalse);
    });

    test('signed out, a sync is not attempted', () async {
      final (c, _) = await containerWith(signedIn: false);
      final result = await c.read(favoritesProvider.notifier).syncFromTmdb();
      expect(result.outcome, TmdbSyncOutcome.signedOut);
    });

    test('a union on sign-in queues what it could not push', () async {
      final account = _Account(failPushes: true);
      final (c, _) = await containerWith(
        account: account,
        prefs: {
          'favorite_movies': jsonEncode([77]),
        },
      );

      await c
          .read(favoritesProvider.notifier)
          .syncFromTmdb(pushLocalFirst: true);

      expect(c.read(favoritesProvider).favoriteMovieIds, {77});
      expect(
        c.read(favoritesProvider.notifier).pendingChanges.single.key,
        'movie:77',
      );
    });

    test('an unreadable list is kept aside, not saved over', () async {
      final (c, _) = await containerWith(
        signedIn: false,
        prefs: {'favorite_shows': 'garbage'},
      );
      expect(c.read(favoritesProvider).favoriteIds, isEmpty);
      expect(
        c.read(sharedPreferencesProvider).getString('favorite_shows.corrupt'),
        'garbage',
      );
    });

    test('the details refetch only when the ids change', () async {
      // Watching the whole state refetched every favorite's details on each
      // `isSyncing` flip — twice per sync.
      final catalogue = _Catalogue();
      final account = _Account(remoteShows: {1, 2});
      final (c, _) = await containerWith(
        account: account,
        catalogue: catalogue,
        prefs: {
          'favorite_shows': jsonEncode([1, 2]),
        },
      );
      final sub = c.listen(favoriteShowsProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(favoriteShowsProvider.future);
      expect(catalogue.detailCalls, 2);

      await c.read(favoritesProvider.notifier).syncFromTmdb();
      await c.read(favoriteShowsProvider.future);
      expect(catalogue.detailCalls, 2);
    });
  });

  group('watchlist', () {
    test('shares the same queue behaviour', () async {
      final account = _Account(failPushes: true);
      final (c, _) = await containerWith(account: account);
      final n = c.read(watchlistProvider.notifier);
      await n.toggleMovie(3);
      await settle();
      await n.syncFromTmdb();

      expect(c.read(watchlistProvider).movieIds, {3});
      expect(account.pushes, isEmpty);
      expect(n.pendingChanges.single.key, 'movie:3');
    });
  });

  group('TmdbIds', () {
    test('equal for the same ids in any order', () {
      expect(TmdbIds([1, 2, 3]), TmdbIds([3, 1, 2]));
      expect(TmdbIds([1, 2]).hashCode, TmdbIds([2, 1]).hashCode);
      expect(TmdbIds([1, 2]), isNot(TmdbIds([1, 3])));
    });
  });

  group('upcoming episodes', () {
    UpcomingEpisode upcoming(String airDate) => UpcomingEpisode(
      show: Show(id: 1, name: 'S'),
      airDate: airDate,
    );

    test('counts calendar days, whatever the hour', () {
      final evening = DateTime(2026, 10, 3, 20);
      expect(upcoming('2026-10-04').daysUntilAirFrom(evening), 1);
      expect(upcoming('2026-10-03').daysUntilAirFrom(evening), 0);
      expect(
        upcoming('2027-07-08').daysUntilAirFrom(DateTime(2026, 10, 3, 23)),
        278,
      );
    });

    test('past air dates are dropped from the list', () async {
      final catalogue = _Catalogue(
        nextAirDates: {1: '2001-01-01', 2: '2099-01-01'},
      );
      final (c, _) = await containerWith(
        signedIn: false,
        catalogue: catalogue,
        prefs: {
          'favorite_shows': jsonEncode([1, 2]),
        },
      );
      final sub = c.listen(upcomingEpisodesProvider, (_, _) {});
      addTearDown(sub.close);

      final list = await c.read(upcomingEpisodesProvider.future);
      expect(list.map((e) => e.show.id), [2]);
      expect(catalogue.detailCalls, 2, reason: 'shared with the shows grid');
    });
  });
}

class _SignedIn extends TmdbSessionNotifier {
  @override
  TmdbSession? build() => TmdbSession(
    accessToken: 'user-token',
    accountId: 7,
    account: TmdbAccount(id: 7, username: 'tester'),
  );
}

class _Account extends TmdbAccountService {
  _Account({
    Set<int>? remoteShows,
    this.failPushes = false,
    this.failReads = false,
  }) : remoteShows = remoteShows ?? {},
       super(accessToken: 'test');

  final Set<int> remoteShows;
  final Set<int> remoteMovies = {};
  bool failPushes;
  final bool failReads;
  final List<String> pushes = [];

  Future<void> _push(String what) async {
    if (failPushes) throw const SocketException('offline');
    pushes.add(what);
  }

  @override
  Future<void> setFavorite({
    required int accountId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool favorite,
  }) => _push('fav ${mediaType.api}:$mediaId ${favorite ? 'on' : 'off'}');

  @override
  Future<void> setWatchlist({
    required int accountId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool watchlist,
  }) => _push('wl ${mediaType.api}:$mediaId ${watchlist ? 'on' : 'off'}');

  Future<Set<int>> _read(Set<int> ids) async {
    if (failReads) throw const SocketException('offline');
    return {...ids};
  }

  @override
  Future<Set<int>> getFavoriteShowIds({required int accountId}) =>
      _read(remoteShows);

  @override
  Future<Set<int>> getFavoriteMovieIds({required int accountId}) =>
      _read(remoteMovies);

  @override
  Future<Set<int>> getWatchlistShowIds({required int accountId}) =>
      _read(remoteShows);

  @override
  Future<Set<int>> getWatchlistMovieIds({required int accountId}) =>
      _read(remoteMovies);
}

class _Catalogue extends TmdbApiService {
  _Catalogue({this.nextAirDates = const {}}) : super(accessToken: 'test');

  final Map<int, String> nextAirDates;
  int detailCalls = 0;

  @override
  Future<Show> getShowDetails(int showId) async {
    detailCalls++;
    final airDate = nextAirDates[showId];
    return Show(
      id: showId,
      name: 'Show $showId',
      inProduction: airDate != null,
      nextEpisode: airDate == null
          ? null
          : Episode(
              id: showId * 10,
              episodeNumber: 1,
              seasonNumber: 2,
              name: 'Next',
              airDate: airDate,
            ),
    );
  }
}
