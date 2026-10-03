import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/movie.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/tmdb_genres.dart';
import 'package:mediahub/widgets/media/media_poster_card.dart';

void main() {
  test('list records keep their vote count and genre ids', () {
    final movie = Movie.fromJson({
      'id': 1,
      'title': 'X',
      'vote_average': 9.5,
      'vote_count': 3,
      'genre_ids': [878, 18],
    });
    expect(movie.voteCount, 3);
    expect(movie.genreIds, [878, 18]);

    final show = Show.fromJson({
      'id': 2,
      'name': 'Y',
      'vote_count': 1200,
      'genre_ids': [10765],
    });
    expect(show.voteCount, 1200);
    expect(show.genreIds, [10765]);
  });

  test('a rating resting on a handful of votes is not shown', () {
    expect(ratingLabel(10, voteCount: 3), isNull);
    expect(ratingLabel(8.4, voteCount: 2400), '★ 8.4');
    // 0 = not reported: shown, as before.
    expect(ratingLabel(7.1), '★ 7.1');
  });

  test('genre ids name the genre on unfiltered feeds', () {
    expect(firstGenreName([878, 18], tv: false), 'Science Fiction');
    expect(firstGenreName([10765], tv: true), 'Sci-Fi & Fantasy');
    expect(firstGenreName([999999, 18], tv: false), 'Drama');
    expect(firstGenreName(const [], tv: false), isNull);
  });
}
