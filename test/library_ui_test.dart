import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/show_with_seasons.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/services/library_actions.dart';
import 'package:mediahub/widgets/common/mediahub_chip.dart';
import 'package:mediahub/widgets/library/library_chrome.dart';
import 'package:mediahub/widgets/library/library_item_actions.dart';
import 'package:mediahub/widgets/library/library_section.dart';
import 'package:mediahub/widgets/library/library_show_drawer.dart';

LocalMediaFile _episode(int n, {bool watched = false}) {
  final path = '/dl/Silo.S01E0$n.1080p.mkv';
  return LocalMediaFile(
    path: path,
    fileName: path.split('/').last,
    sizeBytes: 1 << 30,
    modifiedDate: DateTime(2026),
    extension: 'mkv',
    showName: 'Silo',
    seasonNumber: 1,
    episodeNumber: n,
    progress: watched
        ? WatchProgress(
            fileHash: WatchProgress.generateHash(path),
            filePath: path,
            position: Duration.zero,
            duration: Duration.zero,
            lastWatched: DateTime(2026),
            isCompleted: true,
          )
        : null,
  );
}

ShowWithSeasons _silo(List<LocalMediaFile> files) => ShowWithSeasons(
  showName: 'Silo',
  seasons: {1: files},
  totalEpisodes: files.length,
);

/// The library as the test sets it.
class _Library extends Notifier<List<ShowWithSeasons>> {
  @override
  List<ShowWithSeasons> build() => [
    _silo([_episode(1), _episode(2)]),
  ];

  void set(List<ShowWithSeasons> shows) => state = shows;
}

final _library = NotifierProvider<_Library, List<ShowWithSeasons>>(
  _Library.new,
);

LibraryActions _actions(List<String> log) => LibraryActions(
  playFile: (f) => log.add('play ${f.episodeCode}'),
  playProgress: (p) => log.add('resume'),
  removeProgress: (p) => log.add('remove'),
  markWatched: (f) => log.add('watched ${f.episodeCode}'),
  markNotWatched: (f) => log.add('unwatched ${f.episodeCode}'),
  deleteFile: (f) => log.add('delete ${f.episodeCode}'),
);

void main() {
  group('delete confirmation', () {
    test('says what goes with the file', () {
      expect(
        deleteConfirmationMessage(LibraryDeleteScope.fileInPack, 'Silo S01E02'),
        'Delete this episode only — the rest of the season pack stays in '
        'Transfers.',
      );
      expect(
        deleteConfirmationMessage(LibraryDeleteScope.wholeTorrent, 'Arrival'),
        contains('removes its download from Transfers'),
      );
      expect(
        deleteConfirmationMessage(LibraryDeleteScope.fileOnly, 'Arrival'),
        'This deletes "Arrival" from disk.',
      );
    });
  });

  testWidgets('the show drawer follows the library live', (tester) async {
    // The bottom sheet this replaced rendered a snapshot taken when it
    // opened: a deleted file stayed listed, a watched one kept offering
    // "Mark as watched".
    final log = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMediaByShowAndSeasonProvider.overrideWith(
            (ref) => ref.watch(_library),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LibraryShowDrawer(showName: 'Silo', actions: _actions(log)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('S01E01'), findsOneWidget);
    expect(find.text('S01E02'), findsOneWidget);

    await tester.tap(find.text('S01E01'));
    expect(log, ['play S01E01']);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryShowDrawer)),
    );
    container.read(_library.notifier).set([
      _silo([_episode(1, watched: true)]),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('S01E02'), findsNothing);
    expect(find.textContaining('Watched'), findsOneWidget);
  });

  testWidgets('section chips are the app\'s filter chips, with counts', (
    tester,
  ) async {
    LibrarySection? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryChips(
            selected: LibrarySection.all,
            onChanged: (s) => picked = s,
            counts: const {LibrarySection.movies: 3},
          ),
        ),
      ),
    );
    expect(find.byType(MediaHubFilterChip), findsNWidgets(5));
    await tester.tap(find.text('Movies'));
    expect(picked, LibrarySection.movies);
  });
}
