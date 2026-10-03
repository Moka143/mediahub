import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/movie.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The library's lookups: which file on disk a details page plays, what a
/// library entry knows about itself, and when a poster lookup is retried.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LocalMediaFile movieFile(String name) => LocalMediaFile(
    path: '/lib/$name',
    fileName: name,
    sizeBytes: 1,
    modifiedDate: DateTime(2026),
    extension: 'mkv',
  );

  group('findMovieFile', () {
    final library = [
      movieFile('Upgrade.2018.1080p.mkv'),
      movieFile('Pickup.1951.mkv'),
      movieFile('Dune.2021.2160p.mkv'),
      movieFile('Wonder.Woman.1984.2020.1080p.mkv'),
      movieFile('Amélie.2001.mkv'),
    ];

    LocalMediaFile? find(String title, {int? year}) =>
        findMovieFile(library, title: title, year: year);

    test('a title inside another is not that title', () {
      // "Up" played Upgrade.2018.mkv — and Pickup — off the details page.
      expect(find('Up'), isNull);
      expect(find('Up', year: 2009), isNull);
    });

    test('a title that normalises to nothing matches nothing', () {
      // Non-Latin titles used to normalise to "" — which matched the first
      // movie in the library.
      expect(find('...'), isNull);
      expect(find('千と千尋の神隠し'), isNull);
    });

    test('a title in another script is still compared', () {
      expect(find('Amélie', year: 2001)!.fileName, 'Amélie.2001.mkv');
    });

    test('the year tells two films of one title apart', () {
      expect(find('Dune', year: 2021)!.fileName, 'Dune.2021.2160p.mkv');
      expect(find('Dune', year: 1984), isNull);
    });

    test('a year that is part of the title still finds the film', () {
      expect(
        find('Wonder Woman 1984', year: 2020)!.fileName,
        'Wonder.Woman.1984.2020.1080p.mkv',
      );
      expect(find('Wonder Woman', year: 2017), isNull);
    });

    test('without a year, two films of one title are not guessed between', () {
      final two = [movieFile('Dune.1984.mkv'), movieFile('Dune.2021.mkv')];
      expect(findMovieFile(two, title: 'Dune'), isNull);
    });

    test('episodes are never movies', () {
      final episode = LocalMediaFile(
        path: '/lib/Dune.S01E01.mkv',
        fileName: 'Dune.S01E01.mkv',
        sizeBytes: 1,
        modifiedDate: DateTime(2026),
        showName: 'Dune',
        seasonNumber: 1,
        episodeNumber: 1,
        extension: 'mkv',
      );
      expect(findMovieFile([episode], title: 'Dune'), isNull);
    });
  });

  group('library files', () {
    Future<ProviderContainer> containerWith({
      List<LocalMediaFile> files = const [],
      Map<String, Object> prefs = const {},
      TmdbApiService? tmdb,
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final sp = await SharedPreferences.getInstance();
      final c = ProviderContainer(
        // No automatic retry: a failure should surface at once here.
        retry: (_, _) => null,
        overrides: [
          sharedPreferencesProvider.overrideWithValue(sp),
          localMediaStreamProvider.overrideWith(
            (ref) => Stream<List<LocalMediaFile>>.value(files),
          ),
          if (tmdb != null) tmdbApiServiceProvider.overrideWithValue(tmdb),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('carry the show id and poster their progress row learned', () async {
      // Declared on every library file and set on none: everything that read
      // them — the player's progress rows, the Home poster fallback — got
      // null.
      final file = LocalMediaFile(
        path: '/lib/Severance.S02E04.mkv',
        fileName: 'Severance.S02E04.mkv',
        sizeBytes: 1,
        modifiedDate: DateTime(2026),
        showName: 'Severance',
        seasonNumber: 2,
        episodeNumber: 4,
        extension: 'mkv',
      );
      final c = await containerWith(files: [file]);
      final sub = c.listen(localMediaFilesProvider, (_, _) {});
      addTearDown(sub.close);
      await c
          .read(watchProgressProvider.notifier)
          .markCompleted(file.path, showId: 95396, posterPath: '/p.jpg');

      final joined = (await c.read(localMediaFilesProvider.future)).single;
      expect(joined.showId, 95396);
      expect(joined.isWatched, isTrue);
    });

    test('refreshing rebuilds the scanner, and so the scan', () async {
      final c = await containerWith();
      final before = c.read(localMediaScannerProvider);
      refreshLocalMediaFromRef(_RefProbe.of(c));
      expect(identical(c.read(localMediaScannerProvider), before), isFalse);
    });

    test('a failed poster lookup is not cached as "no poster"', () async {
      final tmdb = _FlakyTmdb();
      final c = await containerWith(tmdb: tmdb);

      final sub = c.listen(showPosterProvider('You'), (_, _) {});
      await expectLater(
        c.read(showPosterProvider('You').future),
        throwsA(isA<TmdbApiException>()),
      );
      sub.close();
      // Nothing watches the failure now; it is let go.
      await Future<void>.delayed(Duration.zero);

      tmdb.online = true;
      final url = await c.read(showPosterProvider('You').future);
      expect(url, contains('/you.jpg'));
    });

    test(
      'the poster is the same show by name, not merely the first hit',
      () async {
        final c = await containerWith(tmdb: _FlakyTmdb()..online = true);
        final sub = c.listen(showPosterProvider('You'), (_, _) {});
        addTearDown(sub.close);
        expect(
          await c.read(showPosterProvider('You').future),
          contains('/you.jpg'),
        );
      },
    );
  });

  group('WatchProgress rows as library files', () {
    test('fromProgress is a usable stand-in', () {
      final file = LocalMediaFile.fromProgress(
        WatchProgress(
          fileHash: WatchProgress.generateHash('/x/Arrival.2016.mkv'),
          filePath: '/x/Arrival.2016.mkv',
          movieId: 329865,
          position: Duration.zero,
          duration: Duration.zero,
          lastWatched: DateTime(2026),
        ),
      );
      expect(file.isVideo, isTrue);
      expect(file.seasonNumber, isNull);
      expect(file.progress!.movieId, 329865);
    });
  });
}

/// A TMDB that is offline until told otherwise, and lists "Young Sheldon"
/// ahead of "You".
class _FlakyTmdb extends TmdbApiService {
  _FlakyTmdb() : super(accessToken: 'test');

  bool online = false;

  @override
  Future<List<Show>> searchShows(
    String query, {
    int page = 1,
    int? firstAirDateYear,
  }) async {
    if (!online) throw TmdbApiException('offline', isNetwork: true);
    return [
      Show(id: 1, name: 'Young Sheldon', posterPath: '/young.jpg'),
      Show(id: 2, name: 'You', posterPath: '/you.jpg'),
    ];
  }

  @override
  Future<List<Movie>> searchMovies(
    String query, {
    int page = 1,
    int? year,
  }) async => const [];
}

/// A provider [Ref] borrowed from [container], for the helpers that take one.
class _RefProbe {
  static Ref of(ProviderContainer container) => container.read(_refProvider);

  static final _refProvider = Provider<Ref>((ref) => ref);
}
