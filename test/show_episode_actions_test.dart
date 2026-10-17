import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/season.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/models/watched_index.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';
import 'package:mediahub/widgets/details/show_episode_actions.dart';
import 'package:mediahub/widgets/editorial/editorial.dart';

final _show = Show(
  id: 7,
  name: 'Silo',
  numberOfSeasons: 2,
  seasons: [
    Season(id: 1, seasonNumber: 1, name: 'Season 1', episodeCount: 10),
    Season(id: 2, seasonNumber: 2, name: 'Season 2', episodeCount: 10),
  ],
);

WatchProgress _progress(int season, int episode, {double done = 1}) =>
    WatchProgress(
      fileHash: '$season/$episode',
      filePath: '/library/Silo.S${season}E$episode.mkv',
      showId: 7,
      seasonNumber: season,
      episodeNumber: episode,
      position: Duration(seconds: (done * 1000).round()),
      duration: const Duration(seconds: 1000),
      lastWatched: DateTime(2026, 10),
    );

void main() {
  final played = <Episode>[];
  var browsed = 0;

  Future<void> pump(
    WidgetTester tester, {
    List<WatchProgress> watched = const [],
    List<WatchProgress> inProgress = const [],
    String? Function(int season, int episode)? airDate,
  }) async {
    played.clear();
    browsed = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          seasonEpisodesProvider.overrideWith(
            (ref, params) async => [
              for (var n = 1; n <= 10; n++)
                Episode(
                  id: params.seasonNumber * 100 + n,
                  episodeNumber: n,
                  seasonNumber: params.seasonNumber,
                  name: 'Episode $n',
                  airDate:
                      airDate?.call(params.seasonNumber, n) ?? '2023-05-05',
                ),
            ],
          ),
          watchedIndexProvider.overrideWithValue(
            WatchedIndex.fromProgress(watched),
          ),
          continueWatchingProvider.overrideWithValue(inProgress),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ShowEpisodeActions(
              show: _show,
              onPlay: played.add,
              onBrowse: () => browsed++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  EditorialButtonKind kindOf(WidgetTester tester, String label) => tester
      .widget<EditorialButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(EditorialButton),
        ),
      )
      .kind;

  testWidgets('Continue plays the episode in progress', (tester) async {
    await pump(
      tester,
      watched: [_progress(2, 1)],
      inProgress: [_progress(1, 5, done: 0.4)],
    );
    expect(find.text('Continue S01E05'), findsOneWidget);
    expect(kindOf(tester, 'Continue S01E05'), EditorialButtonKind.accent);
    // One accent action: Browse steps back.
    expect(kindOf(tester, 'Browse episodes'), EditorialButtonKind.ghost);

    await tester.tap(find.text('Continue S01E05'));
    expect(played.single.episodeCode, 'S01E05');
    expect(browsed, 0);
  });

  testWidgets('Next plays the episode after the furthest watched', (
    tester,
  ) async {
    await pump(tester, watched: [_progress(1, 10)]);
    expect(find.text('Next: S02E01'), findsOneWidget);

    await tester.tap(find.text('Next: S02E01'));
    expect(played.single.episodeCode, 'S02E01');
  });

  testWidgets('a next episode that has not aired is not offered', (
    tester,
  ) async {
    await pump(
      tester,
      watched: [_progress(2, 4)],
      airDate: (season, episode) =>
          season == 2 && episode >= 5 ? '2999-01-01' : null,
    );
    expect(find.textContaining('S02E05'), findsNothing);
    expect(kindOf(tester, 'Browse episodes'), EditorialButtonKind.accent);
  });

  testWidgets('a show never started, or finished, offers only Browse', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byType(EditorialButton), findsOneWidget);
    expect(kindOf(tester, 'Browse episodes'), EditorialButtonKind.accent);

    await pump(tester, watched: [_progress(2, 10)]);
    expect(find.byType(EditorialButton), findsOneWidget);

    await tester.tap(find.text('Browse episodes'));
    expect(browsed, 1);
  });
}
