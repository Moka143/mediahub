import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/movie.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/tmdb_title_resolver.dart';
import 'package:mediahub/utils/error_messages.dart';

/// Title → TMDB id, which the watched-sync writes to the user's account on.
/// Only an unambiguous answer counts; everything else is "no answer".
void main() {
  Movie movie(int id, String title, String? year, {String? original}) => Movie(
    id: id,
    title: title,
    originalTitle: original,
    releaseDate: year == null ? null : '$year-06-01',
  );

  group('pickMovie', () {
    final halloweens = [
      movie(2018, 'Halloween', '2018'),
      movie(1978, 'Halloween', '1978'),
      movie(77, 'Halloween II', '1981'),
    ];

    test('the year picks between films of one title', () {
      expect(
        TmdbTitleResolver.pickMovie(halloweens, (
          title: 'Halloween',
          year: 1978,
        )),
        1978,
      );
    });

    test('no year and two films of that title is no answer', () {
      expect(
        TmdbTitleResolver.pickMovie(halloweens, (
          title: 'Halloween',
          year: null,
        )),
        isNull,
      );
    });

    test('a different title is never taken, however high it ranks', () {
      expect(
        TmdbTitleResolver.pickMovie(
          [movie(1, 'Upgrade', '2018')],
          (title: 'Up', year: null),
        ),
        isNull,
      );
    });

    test('an exact title settles a loose tie', () {
      final runners = [
        movie(78, 'Blade Runner', '1982'),
        movie(335984, 'Blade Runner 2049', '2017'),
      ];
      expect(
        TmdbTitleResolver.pickMovie(runners, (
          title: 'Blade Runner',
          year: null,
        )),
        78,
      );
    });

    test('the original title counts', () {
      expect(
        TmdbTitleResolver.pickMovie(
          [
            movie(
              194,
              'Amélie',
              '2001',
              original: "Le Fabuleux Destin d'Amélie Poulain",
            ),
          ],
          (title: "Le Fabuleux Destin d'Amélie Poulain", year: 2001),
        ),
        194,
      );
    });
  });

  group('pickShow', () {
    final doctors = [
      Show(id: 57243, name: 'Doctor Who', firstAirDate: '2005-03-26'),
      Show(id: 121, name: 'Doctor Who', firstAirDate: '1963-11-23'),
    ];

    test('the first-air year picks the series', () {
      expect(
        TmdbTitleResolver.pickShow(doctors, (title: 'Doctor Who', year: 2005)),
        57243,
      );
    });

    test('without one, there is no answer', () {
      expect(
        TmdbTitleResolver.pickShow(doctors, (title: 'Doctor Who', year: null)),
        isNull,
      );
    });

    test('"You" is not "Young Sheldon"', () {
      expect(
        TmdbTitleResolver.pickShow(
          [Show(id: 1, name: 'Young Sheldon')],
          (title: 'You', year: null),
        ),
        isNull,
      );
    });
  });

  group('resolver', () {
    test('a year that is part of the title is tried as one', () async {
      final tmdb = _Catalogue(
        movies: [
          movie(464052, 'Wonder Woman 1984', '2020'),
          movie(297762, 'Wonder Woman', '2017'),
        ],
      );
      final resolver = TmdbTitleResolver(tmdb);
      expect(
        await resolver.movieId((title: 'Wonder Woman', year: 1984)),
        464052,
      );
    });

    test('answers, misses included, are asked once', () async {
      final tmdb = _Catalogue(movies: [movie(1, 'Arrival', '2016')]);
      final resolver = TmdbTitleResolver(tmdb);
      await resolver.movieId((title: 'Arrival', year: 2016));
      await resolver.movieId((title: 'Arrival', year: 2016));
      await resolver.movieId((title: 'Nope', year: null));
      await resolver.movieId((title: 'Nope', year: null));
      expect(tmdb.searches, 2);
    });

    test('failures are thrown and not remembered', () async {
      final tmdb = _Catalogue(movies: [movie(1, 'Arrival', '2016')])
        ..offline = true;
      final resolver = TmdbTitleResolver(tmdb);
      await expectLater(
        resolver.movieId((title: 'Arrival', year: 2016)),
        throwsA(isA<TmdbApiException>()),
      );
      tmdb.offline = false;
      expect(await resolver.movieId((title: 'Arrival', year: 2016)), 1);
    });

    test('keeps a bounded number of answers', () async {
      final tmdb = _Catalogue();
      final resolver = TmdbTitleResolver(tmdb, maxEntries: 2);
      for (final t in ['a', 'b', 'c', 'a']) {
        await resolver.showId((title: t, year: null));
      }
      expect(tmdb.searches, 4, reason: '"a" was dropped to make room');
    });
  });

  group('TmdbApiException', () {
    DioException dio(DioExceptionType type, {int? status}) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: type,
      response: status == null
          ? null
          : Response(
              requestOptions: RequestOptions(path: '/x'),
              statusCode: status,
            ),
    );

    test('keeps what failed, so a screen can choose the way out', () {
      final rejected = TmdbApiException.fromDio(
        'search shows',
        dio(DioExceptionType.badResponse, status: 401),
      );
      expect(rejected.statusCode, 401);
      expect(classifyFailure(rejected), FailureKind.unauthorized);
      expect(failureNeedsSettings(rejected), isTrue);

      final offline = TmdbApiException.fromDio(
        'search shows',
        dio(DioExceptionType.connectionError),
      );
      expect(offline.isNetwork, isTrue);
      expect(classifyFailure(offline), FailureKind.offline);

      final slow = TmdbApiException.fromDio(
        'search shows',
        dio(DioExceptionType.receiveTimeout),
      );
      expect(classifyFailure(slow), FailureKind.timeout);
    });

    test('the old one-argument form still works', () {
      final legacy = TmdbApiException('boom');
      expect(legacy.statusCode, isNull);
      expect(classifyFailure(legacy), FailureKind.unknown);
    });
  });
}

class _Catalogue extends TmdbApiService {
  _Catalogue({this.movies = const []}) : super(accessToken: 'test');

  final List<Movie> movies;
  bool offline = false;
  int searches = 0;

  @override
  Future<List<Movie>> searchMovies(
    String query, {
    int page = 1,
    int? year,
  }) async {
    searches++;
    if (offline) throw TmdbApiException('offline', isNetwork: true);
    return [
      for (final m in movies)
        if (year == null || m.year == '$year') m,
    ];
  }

  @override
  Future<List<Show>> searchShows(
    String query, {
    int page = 1,
    int? firstAirDateYear,
  }) async {
    searches++;
    return const [];
  }
}
