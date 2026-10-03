import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/tmdb_genres.dart';
import 'package:mediahub/screens/movies_screen.dart';
import 'package:mediahub/screens/shows_screen.dart';
import 'package:mediahub/widgets/common/paged_browse_view.dart';

void main() {
  final now = DateTime(2026, 10, 3);

  group('genre-filtered feeds', () {
    test('Trending and Popular send different queries', () {
      // Discover has no "trending" sort; both used to send popularity.desc.
      final movies = (
        trending: MoviesBrowseConfig.discoverQuery(
          MoviesBrowseConfig.trending,
          now: now,
        ),
        popular: MoviesBrowseConfig.discoverQuery(
          MoviesBrowseConfig.popular,
          now: now,
        ),
      );
      final shows = (
        trending: ShowsBrowseConfig.discoverQuery(
          ShowsBrowseConfig.trending,
          now: now,
        ),
        popular: ShowsBrowseConfig.discoverQuery(
          ShowsBrowseConfig.popular,
          now: now,
        ),
      );
      for (final pair in [movies, shows]) {
        expect(pair.trending, isNot(pair.popular));
        expect(pair.trending.year, 2026);
        expect(pair.popular.year, isNull);
      }
    });

    test('Top rated sorts by average only among well-voted titles', () {
      // A bare vote_average.desc puts titles with three 10/10 votes first.
      for (final top in [
        MoviesBrowseConfig.discoverQuery(MoviesBrowseConfig.topRated),
        ShowsBrowseConfig.discoverQuery(ShowsBrowseConfig.topRated),
      ]) {
        expect(top.sortBy, 'vote_average.desc');
        expect(top.minVotes, greaterThanOrEqualTo(100));
      }
    });
  });

  test('the genre pickers offer every TMDB genre, A to Z after "All"', () {
    for (final (genres, tmdb) in [
      (const MoviesBrowseConfig().genres, tmdbMovieGenres),
      (const ShowsBrowseConfig().genres, tmdbTvGenres),
    ]) {
      expect(genres.first.isAll, isTrue);
      expect(genres.first.label, BrowseGenre.allLabel);

      final rest = genres.skip(1).toList();
      expect({for (final g in rest) ...g.ids}, tmdb.keys.toSet());
      final labels = [for (final g in rest) g.label];
      expect(labels, [...labels]..sort());
    }
  });

  test('no two TV genres query the same genre', () {
    // "Sci-Fi" and "Fantasy" were once two chips both asking for 10765.
    final ids = [
      for (final g in const ShowsBrowseConfig().genres)
        if (!g.isAll) g.ids.join(','),
    ];
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('no two movie genres query the same genre', () {
    final ids = [
      for (final g in const MoviesBrowseConfig().genres)
        if (!g.isAll) g.ids.join(','),
    ];
    expect(ids.toSet(), hasLength(ids.length));
  });
}
