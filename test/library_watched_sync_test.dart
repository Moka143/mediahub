import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/movie.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/providers/tmdb_account_provider.dart';
import 'package:mediahub/providers/tmdb_synced_ids.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';
import 'package:mediahub/services/library_actions.dart';
import 'package:mediahub/services/tmdb_account_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/tmdb_title_resolver.dart';
import 'package:mediahub/services/tmdb_watched_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Watched state ↔ TMDB, signed in.
///
/// TMDB has no "watched" flag; a 10/10 rating stands in for it, and every
/// rating the app posts lands on the user's real account. Two things went
/// wrong here, and both wrote to TMDB:
///
///  * **The wrong title.** Resolution took the first search hit for the
///    title with its year stripped, so `Halloween.1978…` rated whichever
///    Halloween ranked first. Only an unambiguous match is acted on now.
///  * **Offline marks erased.** A mark made while TMDB could not be reached
///    looked, at the next launch's reconcile, exactly like one removed on
///    another device — and was removed here too. It now stays pending, and
///    is pushed instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('mediahub_watched_sync');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  LocalMediaFile mediaFile(
    String name, {
    String? showName,
    int? season,
    int? episode,
    int? showId,
  }) {
    final path = p.join(tmp.path, name);
    return LocalMediaFile(
      path: path,
      fileName: name,
      sizeBytes: 2 * minPlayableBytes,
      modifiedDate: DateTime(2026, 1, 1),
      showName: showName,
      seasonNumber: season,
      episodeNumber: episode,
      showId: showId,
      extension: 'mkv',
    );
  }

  Future<WidgetRef> pumpRef(
    WidgetTester tester, {
    required _FakeAccount account,
    _FakeTmdb? tmdb,
    List<LocalMediaFile> library = const [],
    List<WatchProgress> progress = const [],
  }) async {
    SharedPreferences.setMockInitialValues({
      if (progress.isNotEmpty)
        'watch_progress': jsonEncode([for (final r in progress) r.toJson()]),
    });
    final prefs = await SharedPreferences.getInstance();
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          tmdbSessionProvider.overrideWith(_SignedIn.new),
          tmdbAccountServiceProvider.overrideWithValue(account),
          tmdbApiServiceProvider.overrideWithValue(tmdb ?? _FakeTmdb()),
          localMediaFilesProvider.overrideWith((ref) async => library),
          localMediaStreamProvider.overrideWith(
            (ref) => Stream<List<LocalMediaFile>>.value(library),
          ),
        ],
        child: Consumer(
          builder: (context, ref, child) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // Let the library future resolve, so reconcile sees the files.
    await tester.runAsync(() => captured.read(localMediaFilesProvider.future));
    return captured;
  }

  WatchProgress? rowFor(WidgetRef ref, String path) =>
      ref.read(watchProgressProvider)[WatchProgress.generateHash(path)];

  WatchProgress row(
    String path, {
    bool completed = true,
    int? showId,
    int? season,
    int? episode,
    int? movieId,
    String? showName,
    Duration position = Duration.zero,
    Duration duration = Duration.zero,
    bool pending = false,
  }) => WatchProgress(
    fileHash: WatchProgress.generateHash(path),
    filePath: path,
    showName: showName,
    showId: showId,
    seasonNumber: season,
    episodeNumber: episode,
    movieId: movieId,
    position: position,
    duration: duration,
    lastWatched: DateTime(2026, 1, 1),
    isCompleted: completed,
    tmdbPushPending: pending,
  );

  group('markAsWatched, signed in', () {
    testWidgets('rates the movie the file names, year included', (
      tester,
    ) async {
      final account = _FakeAccount();
      final ref = await pumpRef(
        tester,
        account: account,
        tmdb: _FakeTmdb(
          movies: [
            Movie(id: 2018, title: 'Halloween', releaseDate: '2018-10-19'),
            Movie(id: 1978, title: 'Halloween', releaseDate: '1978-10-25'),
          ],
        ),
      );
      final file = mediaFile('Halloween.1978.1080p.BluRay.mkv');

      await tester.runAsync(() => markAsWatched(ref, file));

      expect(account.calls, contains('rateMovie 1978'));
      expect(account.calls, contains('watchlist movie 1978 off'));
      expect(account.calls.join(), isNot(contains('2018')));
      expect(rowFor(ref, file.path)!.movieId, 1978);
      expect(rowFor(ref, file.path)!.tmdbPushPending, isFalse);
    });

    testWidgets('writes nothing to TMDB for an ambiguous title', (
      tester,
    ) async {
      // "Dune" with no year: TMDB has two films of that exact title. Rating
      // the first was the old answer; no rating is the right one.
      final account = _FakeAccount();
      final ref = await pumpRef(
        tester,
        account: account,
        tmdb: _FakeTmdb(
          movies: [
            Movie(id: 438631, title: 'Dune', releaseDate: '2021-09-15'),
            Movie(id: 841, title: 'Dune', releaseDate: '1984-12-14'),
          ],
        ),
      );
      final file = mediaFile('Dune.mkv');

      await tester.runAsync(() => markAsWatched(ref, file));

      expect(account.calls, isEmpty);
      final entry = rowFor(ref, file.path)!;
      expect(entry.isCompleted, isTrue, reason: 'the local mark still holds');
      expect(entry.movieId, isNull);
      expect(entry.tmdbPushPending, isFalse, reason: 'nothing to push to');
    });

    testWidgets('rates the episode of the show it resolves to', (tester) async {
      final account = _FakeAccount();
      final ref = await pumpRef(
        tester,
        account: account,
        tmdb: _FakeTmdb(
          shows: [
            Show(id: 57243, name: 'Doctor Who', firstAirDate: '2005-03-26'),
            Show(id: 121, name: 'Doctor Who', firstAirDate: '1963-11-23'),
          ],
        ),
      );
      final file = mediaFile(
        'Doctor.Who.2005.S01E01.mkv',
        showName: 'Doctor Who',
        season: 1,
        episode: 1,
      );

      await tester.runAsync(() => markAsWatched(ref, file));

      expect(account.calls, ['rateEpisode 57243/1/1']);
      expect(rowFor(ref, file.path)!.showId, 57243);
    });

    testWidgets('a failed push stays pending for the next reconcile', (
      tester,
    ) async {
      final account = _FakeAccount(failWrites: true);
      final ref = await pumpRef(tester, account: account);
      final file = mediaFile(
        'Severance.S02E04.mkv',
        showName: 'Severance',
        season: 2,
        episode: 4,
        showId: 95396,
      );

      await tester.runAsync(() => markAsWatched(ref, file));

      final entry = rowFor(ref, file.path)!;
      expect(entry.isCompleted, isTrue);
      expect(entry.tmdbPushPending, isTrue);
      expect(entry.followsRemoteUnwatch, isFalse);
    });

    testWidgets('un-rating a whole show is reachable', (tester) async {
      // The show branch was dead: the id was only ever looked up for files
      // with an episode code, so a show-level mark could never be undone.
      final account = _FakeAccount();
      final ref = await pumpRef(tester, account: account);
      final file = mediaFile('Some.Show.Complete.mkv');

      await tester.runAsync(() => markAsNotWatched(ref, file, tmdbShowId: 42));

      expect(account.calls, ['deleteShowRating 42']);
    });
  });

  group('reconcileWatchedWithTmdb, signed in', () {
    testWidgets('marks what TMDB has rated', (tester) async {
      final file = mediaFile(
        'Andor.S01E06.mkv',
        showName: 'Andor',
        season: 1,
        episode: 6,
        showId: 83867,
      );
      final account = _FakeAccount(
        ratedEpisodes: [(showId: 83867, season: 1, episode: 6)],
      );
      final ref = await pumpRef(tester, account: account, library: [file]);

      final result = await tester.runAsync(() => reconcileWatchedWithTmdb(ref));

      expect(result!.outcome, TmdbSyncOutcome.synced);
      expect(rowFor(ref, file.path)!.isCompleted, isTrue);
    });

    testWidgets('says so when TMDB cannot be read', (tester) async {
      final ref = await pumpRef(tester, account: _FakeAccount(failReads: true));

      final result = await tester.runAsync(() => reconcileWatchedWithTmdb(ref));

      expect(result!.ok, isFalse);
      expect(result.message, isNot(contains('Exception')));
    });

    testWidgets('an explicit mark follows a rating removed elsewhere', (
      tester,
    ) async {
      final path = p.join(tmp.path, 'Andor.S01E06.mkv');
      final ref = await pumpRef(
        tester,
        account: _FakeAccount(),
        progress: [row(path, showId: 83867, season: 1, episode: 6)],
      );

      await tester.runAsync(() => reconcileWatchedWithTmdb(ref));

      expect(rowFor(ref, path)!.isCompleted, isFalse);
    });

    testWidgets('a pending mark is pushed instead of erased', (tester) async {
      // Marked offline: TMDB has no rating yet, and that must not read as
      // "un-marked on another device".
      final path = p.join(tmp.path, 'Andor.S01E06.mkv');
      final account = _FakeAccount();
      final ref = await pumpRef(
        tester,
        account: account,
        progress: [
          row(path, showId: 83867, season: 1, episode: 6, pending: true),
        ],
      );

      await tester.runAsync(() => reconcileWatchedWithTmdb(ref));

      expect(account.calls, contains('rateEpisode 83867/1/6'));
      final entry = rowFor(ref, path)!;
      expect(entry.isCompleted, isTrue);
      expect(entry.tmdbPushPending, isFalse);
    });

    testWidgets('a mark that still cannot be pushed stays', (tester) async {
      final path = p.join(tmp.path, 'Andor.S01E06.mkv');
      final ref = await pumpRef(
        tester,
        account: _FakeAccount(failWrites: true),
        progress: [
          row(path, showId: 83867, season: 1, episode: 6, pending: true),
        ],
      );

      await tester.runAsync(() => reconcileWatchedWithTmdb(ref));

      final entry = rowFor(ref, path)!;
      expect(entry.isCompleted, isTrue);
      expect(entry.tmdbPushPending, isTrue);
    });

    testWidgets('a movie un-rated elsewhere leaves its synthetic row too', (
      tester,
    ) async {
      // These rows were skipped by the pull, so they stayed watched for
      // good — and were re-marked, with a full rewrite, every launch.
      const path = 'tmdb:rated-movie:550';
      final ref = await pumpRef(
        tester,
        account: _FakeAccount(),
        progress: [row(path, movieId: 550)],
      );

      await tester.runAsync(() => reconcileWatchedWithTmdb(ref));

      expect(rowFor(ref, path)!.isCompleted, isFalse);
    });

    testWidgets('nothing new from TMDB writes nothing', (tester) async {
      const path = 'tmdb:rated-movie:550';
      final ref = await pumpRef(
        tester,
        account: _FakeAccount(ratedMovies: {550}),
        progress: [row(path, movieId: 550)],
      );
      // Load the history first, then swap what is on disk for a value no
      // save would produce — so any write at all shows up.
      expect(rowFor(ref, path)!.isCompleted, isTrue);
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setString('watch_progress', '__probe__');

      await tester.runAsync(() => reconcileWatchedWithTmdb(ref));

      expect(prefs.getString('watch_progress'), '__probe__');
    });
  });

  group('planWatchedReconcile', () {
    test('creates a synthetic row only for what nothing here covers', () {
      final plan = planWatchedReconcile(
        progress: {
          for (final r in [row('/a.mkv', showId: 1, season: 1, episode: 1)])
            r.fileHash: r,
        },
        files: const [],
        ratedEpisodes: [
          (showId: 1, season: 1, episode: 1),
          (showId: 1, season: 1, episode: 2),
        ],
        ratedMovieIds: const {},
        now: DateTime(2026, 10, 3),
      );
      expect(plan.unwatch, isEmpty);
      expect(plan.upserts.values.map((r) => r.filePath), ['tmdb:rated:1/1/2']);
    });

    test('never un-marks a title played to the credits', () {
      final played = row(
        '/a.mkv',
        showId: 1,
        season: 1,
        episode: 1,
        position: const Duration(minutes: 57),
        duration: const Duration(minutes: 60),
      );
      final plan = planWatchedReconcile(
        progress: {played.fileHash: played},
        files: const [],
        ratedEpisodes: const [],
        ratedMovieIds: const {},
      );
      expect(plan.isEmpty, isTrue);
    });

    test('uses ids resolved for rows that store none', () {
      final bare = row('/Arrival.2016.mkv', completed: false);
      final plan = planWatchedReconcile(
        progress: {bare.fileHash: bare},
        files: const [],
        ratedEpisodes: const [],
        ratedMovieIds: const {329865},
        resolvedMovieIds: const {'/Arrival.2016.mkv': 329865},
      );
      final marked = plan.upserts[bare.fileHash]!;
      expect(marked.isCompleted, isTrue);
      expect(marked.movieId, 329865);
      expect(
        plan.upserts.keys.where((k) => k != bare.fileHash),
        isEmpty,
        reason: 'the movie is covered — no synthetic row as well',
      );
    });
  });

  group('TmdbWatchedSync.targetFor', () {
    test('an episode needs its show identified, or nothing is done', () async {
      final sync = TmdbWatchedSync(
        account: _FakeAccount(),
        resolver: _resolver(
          _FakeTmdb(
            shows: [
              Show(id: 1, name: 'The Office', firstAirDate: '2005-03-24'),
              Show(id: 2, name: 'The Office', firstAirDate: '2001-07-09'),
            ],
          ),
        ),
        accountId: 7,
      );
      // Two shows of that exact name: no answer, not the first one.
      expect(
        await sync.targetFor(
          path: '/The.Office.S01E01.mkv',
          season: 1,
          episode: 1,
        ),
        isNull,
      );
    });
  });
}

TmdbTitleResolver _resolver(_FakeTmdb tmdb) => TmdbTitleResolver(tmdb);

class _SignedIn extends TmdbSessionNotifier {
  @override
  TmdbSession? build() => TmdbSession(
    accessToken: 'user-token',
    accountId: 7,
    account: TmdbAccount(id: 7, username: 'tester'),
  );
}

/// A TMDB catalogue answering searches from fixed lists.
class _FakeTmdb extends TmdbApiService {
  _FakeTmdb({this.shows = const [], this.movies = const []})
    : super(accessToken: 'test');

  final List<Show> shows;
  final List<Movie> movies;

  @override
  Future<List<Show>> searchShows(
    String query, {
    int page = 1,
    int? firstAirDateYear,
  }) async => [
    for (final s in shows)
      if (firstAirDateYear == null || s.year == '$firstAirDateYear') s,
  ];

  @override
  Future<List<Movie>> searchMovies(
    String query, {
    int page = 1,
    int? year,
  }) async => [
    for (final m in movies)
      if (year == null || m.year == '$year') m,
  ];
}

/// A TMDB account that records every write and answers the rated lists.
class _FakeAccount extends TmdbAccountService {
  _FakeAccount({
    this.ratedEpisodes = const [],
    this.ratedMovies = const {},
    this.failWrites = false,
    this.failReads = false,
  }) : super(accessToken: 'test');

  final List<({int showId, int season, int episode})> ratedEpisodes;
  final Set<int> ratedMovies;
  final bool failWrites;
  final bool failReads;
  final List<String> calls = [];

  Future<void> _write(String call) async {
    if (failWrites) throw const SocketException('offline');
    calls.add(call);
  }

  @override
  Future<void> rateEpisode({
    required int seriesId,
    required int seasonNumber,
    required int episodeNumber,
    required double value,
  }) => _write('rateEpisode $seriesId/$seasonNumber/$episodeNumber');

  @override
  Future<void> deleteEpisodeRating({
    required int seriesId,
    required int seasonNumber,
    required int episodeNumber,
  }) => _write('deleteEpisodeRating $seriesId/$seasonNumber/$episodeNumber');

  @override
  Future<void> rateMovie({required int movieId, required double value}) =>
      _write('rateMovie $movieId');

  @override
  Future<void> deleteMovieRating({required int movieId}) =>
      _write('deleteMovieRating $movieId');

  @override
  Future<void> rateShow({required int seriesId, required double value}) =>
      _write('rateShow $seriesId');

  @override
  Future<void> deleteShowRating({required int seriesId}) =>
      _write('deleteShowRating $seriesId');

  @override
  Future<void> setWatchlist({
    required int accountId,
    required TmdbMediaType mediaType,
    required int mediaId,
    required bool watchlist,
  }) =>
      _write('watchlist ${mediaType.api} $mediaId ${watchlist ? 'on' : 'off'}');

  @override
  Future<List<TmdbRatedEpisode>> getRatedEpisodes({
    required int accountId,
  }) async {
    if (failReads) throw const SocketException('offline');
    return [
      for (final e in ratedEpisodes)
        TmdbRatedEpisode(
          showId: e.showId,
          seasonNumber: e.season,
          episodeNumber: e.episode,
        ),
    ];
  }

  @override
  Future<Set<int>> getRatedMovieIds({required int accountId}) async => {
    ...ratedMovies,
  };
}
