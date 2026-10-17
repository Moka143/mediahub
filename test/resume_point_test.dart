import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/season.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/models/watched_index.dart';
import 'package:mediahub/widgets/episodes/resume_point.dart';

final _show = Show(id: 7, name: 'Silo', numberOfSeasons: 3);
final _seasons = [
  Season(id: 0, seasonNumber: 0, name: 'Specials', episodeCount: 4),
  Season(id: 1, seasonNumber: 1, name: 'Season 1', episodeCount: 10),
  Season(id: 2, seasonNumber: 2, name: 'Season 2', episodeCount: 10),
  Season(id: 3, seasonNumber: 3, name: 'Season 3', episodeCount: 8),
];

/// A row of watch progress: [done] of the way through.
WatchProgress _row(
  int season,
  int episode, {
  double done = 1,
  int? showId = 7,
  String? showName,
  int minute = 0,
}) => WatchProgress(
  fileHash: '$showId/$showName/$season/$episode',
  filePath: '/library/S${season}E$episode.mkv',
  showId: showId,
  showName: showName,
  seasonNumber: season,
  episodeNumber: episode,
  position: Duration(seconds: (done * 1000).round()),
  duration: const Duration(seconds: 1000),
  lastWatched: DateTime(2026, 10, 1, 20, minute),
);

ResumePoint? _pick({
  List<WatchProgress> inProgress = const [],
  List<WatchProgress> watched = const [],
}) => ResumePoint.pick(
  show: _show,
  seasons: _seasons,
  inProgress: inProgress,
  watched: WatchedIndex.fromProgress(watched),
);

void main() {
  test('an episode in progress beats the next unwatched one', () {
    final pick = _pick(
      inProgress: [_row(1, 4, done: 0.4)],
      watched: [_row(2, 3)],
    );
    expect(pick, const ResumePoint(season: 1, episode: 4, inProgress: true));
    expect(pick!.label, 'Continue S01E04');
  });

  test('the most recent episode in progress is the one continued', () {
    // Continue Watching's order: most recent first.
    final pick = _pick(
      inProgress: [_row(3, 2, done: 0.2, minute: 30), _row(2, 9, done: 0.5)],
    );
    expect(pick, const ResumePoint(season: 3, episode: 2, inProgress: true));
  });

  test('otherwise the episode after the furthest one watched', () {
    final pick = _pick(watched: [_row(1, 1), _row(2, 5), _row(1, 9)]);
    expect(pick, const ResumePoint(season: 2, episode: 6, inProgress: false));
    expect(pick!.label, 'Next: S02E06');
  });

  test('a season watched to its end leads to the next season', () {
    expect(
      _pick(watched: [_row(1, 10)]),
      const ResumePoint(season: 2, episode: 1, inProgress: false),
    );
  });

  test('a show watched to its last episode has nothing to continue', () {
    // The drawer then opens on season 1 and the page offers only Browse.
    expect(_pick(watched: [_row(3, 8)]), isNull);
  });

  test('a show never started has nothing to continue', () {
    expect(_pick(), isNull);
  });

  test("another show's progress is not this show's", () {
    expect(
      _pick(
        inProgress: [_row(1, 4, done: 0.4, showId: 8)],
        watched: [_row(2, 3, showId: 8)],
      ),
      isNull,
    );
  });

  test('rows saved without a show id are matched by title', () {
    expect(
      _pick(
        inProgress: [_row(1, 2, done: 0.3, showId: null, showName: 'Silo')],
      ),
      const ResumePoint(season: 1, episode: 2, inProgress: true),
    );
    expect(
      _pick(watched: [_row(2, 2, showId: null, showName: 'Silo 2023')]),
      const ResumePoint(season: 2, episode: 3, inProgress: false),
    );
    // A name that merely starts the same is another show.
    expect(
      _pick(watched: [_row(2, 2, showId: null, showName: 'Silos and More')]),
      isNull,
    );
  });

  test('specials are never a resume point', () {
    expect(
      _pick(inProgress: [_row(0, 2, done: 0.5)], watched: [_row(0, 4)]),
      isNull,
    );
  });
}
