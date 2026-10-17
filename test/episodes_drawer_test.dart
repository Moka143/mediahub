import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/season.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/models/watched_index.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';
import 'package:mediahub/widgets/episodes/episode_row.dart';
import 'package:mediahub/widgets/episodes/episode_status.dart';
import 'package:mediahub/widgets/episodes/season_tabs.dart';
import 'package:mediahub/widgets/mediahub_episodes_drawer.dart';

Torrent _torrent(
  String name, {
  double progress = 1,
  String state = 'uploading',
}) => Torrent.fromJson({
  'hash': name,
  'name': name,
  'progress': progress,
  'state': state,
});

Episode _episode(int n, {int season = 1}) => Episode(
  id: season * 100 + n,
  episodeNumber: n,
  seasonNumber: season,
  name: 'Episode $n',
);

/// Watch progress for Silo (show 7) — [done] of the way through.
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
  group('TransfersEpisodeIndex', () {
    test('only a finished torrent counts as downloaded', () {
      // A paused or errored torrent at 10% used to read DOWNLOADED, and its
      // "Open" button then sent the user to the source picker.
      final index = TransfersEpisodeIndex.from([
        _torrent('Silo.S01E02.1080p.WEB', progress: 0.1, state: 'pausedDL'),
        _torrent('Silo.S01E03.1080p.WEB'),
      ]);
      expect(index.statusOf('Silo', 1, 2), EpisodeStatus.downloading);
      expect(index.statusOf('Silo', 1, 3), EpisodeStatus.downloaded);
      expect(index.statusOf('Silo', 1, 4), EpisodeStatus.none);
    });

    test('matches the whole show name, not its first word', () {
      // "The Bear" matched every torrent containing "the" with the same code.
      final index = TransfersEpisodeIndex.from([
        _torrent('The.Office.US.S02E05.720p'),
      ]);
      expect(index.statusOf('The Bear', 2, 5), EpisodeStatus.none);
      expect(index.statusOf('The Office', 2, 5), EpisodeStatus.downloaded);
    });

    test('episode codes are exact — E01 is not E10', () {
      final index = TransfersEpisodeIndex.from([_torrent('Silo.S01E10.mkv')]);
      expect(index.statusOf('Silo', 1, 1), EpisodeStatus.none);
      expect(index.statusOf('Silo', 1, 10), EpisodeStatus.downloaded);
    });

    test('compares by value, so selecting it skips idle polls', () {
      final a = TransfersEpisodeIndex.from([_torrent('Silo.S01E01')]);
      final b = TransfersEpisodeIndex.from([_torrent('Silo.S01E01')]);
      expect(a, b);
      expect(
        a,
        isNot(
          TransfersEpisodeIndex.from([
            _torrent('Silo.S01E01', progress: 0.5, state: 'downloading'),
          ]),
        ),
      );
    });
  });

  test('downloaded and downloading are told apart by colour', () {
    expect(
      EpisodeStatus.downloaded.color,
      isNot(EpisodeStatus.downloading.color),
    );
  });

  group('MediaHubEpisodesDrawer', () {
    final show = Show(id: 7, name: 'Silo', numberOfSeasons: 1);
    final seasons = [
      Season(id: 1, seasonNumber: 1, name: 'Season 1', episodeCount: 22),
    ];

    Future<void> pump(
      WidgetTester tester, {
      List<Episode>? episodes,
      List<Torrent> torrents = const [],
      Object? error,
      List<Season>? seasonList,
      int? initialSeason = 1,
      List<WatchProgress> watched = const [],
      List<WatchProgress> inProgress = const [],
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            seasonEpisodesProvider.overrideWith((ref, params) async {
              if (error != null) throw error;
              return episodes ??
                  [
                    for (var i = 1; i <= 22; i++)
                      _episode(i, season: params.seasonNumber),
                  ];
            }),
            watchedIndexProvider.overrideWithValue(
              WatchedIndex.fromProgress(watched),
            ),
            transfersEpisodeIndexProvider.overrideWithValue(
              TransfersEpisodeIndex.from(torrents),
            ),
            localMediaFilesProvider.overrideWith(
              (ref) async => const <LocalMediaFile>[],
            ),
            continueWatchingProvider.overrideWithValue(inProgress),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: MediaHubEpisodesDrawer(
                show: show,
                seasons: seasonList ?? seasons,
                initialSeason: initialSeason,
                onEpisodeTap: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('quick-jump reaches an episode that has not been built yet', (
      tester,
    ) async {
      await pump(tester);
      // A lazy list builds only what is on screen: episode 15 does not
      // exist yet, which is why the GlobalKey lookup did nothing.
      expect(find.text('Episode 15'), findsNothing);

      await tester.tap(find.text('15'));
      await tester.pumpAndSettle();

      expect(find.text('Episode 15'), findsOneWidget);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      final extent = EpisodeRow.extentFor(
        MediaQuery.textScalerOf(tester.element(find.byType(ListView))),
      );
      expect(scrollable.position.pixels, closeTo(14 * extent, 0.5));
    });

    testWidgets('rows say what clicking them will do', (tester) async {
      await pump(
        tester,
        episodes: [_episode(1), _episode(2), _episode(3)],
        torrents: [
          _torrent('Silo.S01E01.1080p.WEB'),
          _torrent('Silo.S01E02.1080p', progress: 0.1, state: 'pausedDL'),
        ],
      );
      expect(find.text('Play'), findsOneWidget); // E01, finished
      expect(find.text('Downloading'), findsOneWidget); // E02, in Transfers
      expect(find.text('Stream'), findsOneWidget); // E03, nothing yet
    });

    testWidgets('a failed season says why and offers Try again', (
      tester,
    ) async {
      await pump(tester, error: Exception('Failed host lookup'));
      expect(find.text("Couldn't load episodes"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a season with no episodes says so instead of going blank', (
      tester,
    ) async {
      await pump(tester, episodes: const []);
      expect(
        find.text('No episodes listed for this season yet.'),
        findsOneWidget,
      );
    });

    group('opens where the viewer left off', () {
      final threeSeasons = [
        for (var n = 1; n <= 3; n++)
          Season(id: n, seasonNumber: n, name: 'Season $n', episodeCount: 22),
      ];

      Future<void> open(
        WidgetTester tester, {
        List<WatchProgress> watched = const [],
        List<WatchProgress> inProgress = const [],
      }) => pump(
        tester,
        seasonList: threeSeasons,
        initialSeason: null,
        watched: watched,
        inProgress: inProgress,
      );

      int selectedSeason(WidgetTester tester) =>
          tester.widget<SeasonTabs>(find.byType(SeasonTabs)).selected;

      double scrolledRows(WidgetTester tester) {
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        );
        final extent = EpisodeRow.extentFor(
          MediaQuery.textScalerOf(tester.element(find.byType(ListView))),
        );
        return scrollable.position.pixels / extent;
      }

      testWidgets('an episode in progress beats the next unwatched one', (
        tester,
      ) async {
        await open(
          tester,
          watched: [_progress(3, 4)],
          inProgress: [_progress(2, 12, done: 0.4)],
        );
        expect(selectedSeason(tester), 2);
        expect(scrolledRows(tester), closeTo(11, 0.01));
        expect(find.text('Episode 12'), findsOneWidget);
      });

      testWidgets('otherwise the episode after the furthest watched', (
        tester,
      ) async {
        await open(tester, watched: [_progress(1, 3), _progress(3, 9)]);
        expect(selectedSeason(tester), 3);
        expect(scrolledRows(tester), closeTo(9, 0.01)); // E10
        expect(find.text('Episode 10'), findsOneWidget);
      });

      testWidgets('a fully watched show opens at the top of season 1', (
        tester,
      ) async {
        await open(tester, watched: [_progress(3, 22)]);
        expect(selectedSeason(tester), 1);
        expect(scrolledRows(tester), 0);
      });

      testWidgets('another season picked opens at its top', (tester) async {
        await open(tester, inProgress: [_progress(2, 12, done: 0.4)]);
        await tester.tap(
          find.descendant(
            of: find.byType(SeasonTabs),
            matching: find.text('03'),
          ),
        );
        await tester.pumpAndSettle();
        expect(selectedSeason(tester), 3);
        expect(scrolledRows(tester), 0);
      });
    });

    test('a show with only specials still gets a tab', () {
      final specialsOnly = [
        Season(id: 1, seasonNumber: 0, name: 'Specials', episodeCount: 3),
      ];
      expect(MediaHubEpisodesDrawer.tabSeasons(specialsOnly), [0]);
      expect(MediaHubEpisodesDrawer.tabSeasons([...specialsOnly, ...seasons]), [
        1,
      ]);
    });
  });
}
