import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/movie.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/providers/home_recommendations_provider.dart';

Show _show(int id, String name) => Show(id: id, name: name);
Movie _movie(int id, String title) => Movie(id: id, title: title);

void main() {
  group('buildHomeRecommendationFeed', () {
    test('round-robins seeds and skips titles the user already has', () {
      final feed = buildHomeRecommendationFeed(
        showSeeds: [
          (
            id: 1,
            name: 'Lioness',
            recs: [
              _show(1, 'Lioness'),
              _show(10, 'The Night Agent'),
              _show(11, 'Jack Ryan'),
            ],
          ),
          (
            id: 2,
            name: 'Shogun',
            recs: [_show(12, 'Shogun'), _show(13, 'Tokyo Vice')],
          ),
        ],
        movieSeeds: [
          (
            id: 100,
            name: 'Dune',
            recs: [_movie(200, 'Dune: Part Two'), _movie(201, 'Blade Runner')],
          ),
        ],
        excludeShowIds: {1, 2, 12},
        excludeMovieIds: {100},
      );

      expect(feed, isNotNull);
      expect(feed!.becauseTitle, 'Lioness');
      expect(feed.items.map((i) => i.title).toList(), [
        'The Night Agent',
        'Tokyo Vice',
        'Dune: Part Two',
        'Jack Ryan',
        'Blade Runner',
      ]);
    });

    test('returns null when every neighbor is already excluded', () {
      final feed = buildHomeRecommendationFeed(
        showSeeds: [
          (id: 1, name: 'Lioness', recs: [_show(10, 'The Night Agent')]),
        ],
        movieSeeds: const [],
        excludeShowIds: {1, 10},
        excludeMovieIds: const {},
      );
      expect(feed, isNull);
    });

    test('caps the row', () {
      final recs = [for (var i = 20; i < 50; i++) _show(i, 'Show $i')];
      final feed = buildHomeRecommendationFeed(
        showSeeds: [(id: 1, name: 'Lioness', recs: recs)],
        movieSeeds: const [],
        excludeShowIds: {1},
        excludeMovieIds: const {},
        limit: 5,
      );
      expect(feed!.items, hasLength(5));
    });

    test('the daily window slides so one favorite is not frozen', () {
      final recs = [for (var i = 20; i < 40; i++) _show(i, 'Show $i')];
      final day0 = buildHomeRecommendationFeed(
        showSeeds: [(id: 1, name: 'Lioness', recs: recs)],
        movieSeeds: const [],
        excludeShowIds: {1},
        excludeMovieIds: const {},
        dayIndex: 0,
        limit: 5,
      );
      final day1 = buildHomeRecommendationFeed(
        showSeeds: [(id: 1, name: 'Lioness', recs: recs)],
        movieSeeds: const [],
        excludeShowIds: {1},
        excludeMovieIds: const {},
        dayIndex: 1,
        limit: 5,
      );
      expect(day0!.items.first.id, 20);
      expect(day1!.items.first.id, isNot(20));
      expect(day0.items.map((i) => i.id), isNot(day1.items.map((i) => i.id)));
    });
  });

  group('pickDailySeeds', () {
    test('rotates the primary seed by day and keeps a backup', () {
      final day0 = pickDailySeeds(
        showIds: [1, 2, 3],
        movieIds: const [],
        dayIndex: 0,
      );
      final day1 = pickDailySeeds(
        showIds: [1, 2, 3],
        movieIds: const [],
        dayIndex: 1,
      );
      expect(day0.map((s) => s.id).toList(), [1, 2]);
      expect(day1.map((s) => s.id).toList(), [2, 3]);
    });

    test('the same day always picks the same seeds', () {
      final a = pickDailySeeds(showIds: [1, 2], movieIds: [100], dayIndex: 4);
      final b = pickDailySeeds(showIds: [1, 2], movieIds: [100], dayIndex: 4);
      expect(a, b);
    });
  });
}
