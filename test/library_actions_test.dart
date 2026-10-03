import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_action_result.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/shows_provider.dart';
import 'package:mediahub/providers/tmdb_account_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/providers/watch_progress_provider.dart';
import 'package:mediahub/services/library_actions.dart';
import 'package:mediahub/services/qbittorrent_api_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the library actions — the code that **deletes the user's files**.
///
/// The cases concentrate on the things that cost a user something real:
///
///  * **Which torrent a file belongs to.** The bundled engine puts a
///    single-file torrent straight into the download folder and reports that
///    folder as its content path. The old prefix test therefore matched every
///    file in the library to whichever such torrent came first, and deleting
///    library file B deleted torrent A — with its files. Ownership is now
///    decided by the torrent's own file list, path for path.
///  * **How much goes.** One episode of a season pack is deselected and
///    deleted on its own; the rest of the pack stays.
///  * [isFileCompleteOnDisk]'s refusal to trust `existsSync()`: engines
///    pre-allocate, so a 0.6% file is present at full size.
///
/// Every function here takes a [WidgetRef], and `WidgetRef` is sealed, so it
/// cannot be faked — [pumpRef] captures a real one from a [Consumer] inside a
/// [ProviderScope]. Real file I/O does not complete under the fake clock a
/// `testWidgets` body runs in, so the calls themselves go through
/// `tester.runAsync`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('mediahub_library_actions');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── Fixtures ───────────────────────────────────────────────────────────

  /// A file of [bytes] length under the temp root, created sparsely so a
  /// "big enough to be real media" fixture costs no I/O.
  File makeFile(String relative, {int bytes = 2 * minPlayableBytes}) {
    final file = File(p.join(tmp.path, relative));
    file.parent.createSync(recursive: true);
    final raf = file.openSync(mode: FileMode.write);
    if (bytes > 0) raf.truncateSync(bytes);
    raf.closeSync();
    return file;
  }

  String absent(String name) => p.join(tmp.path, name);

  LocalMediaFile mediaFile(
    String path, {
    String? showName,
    int? season,
    int? episode,
    int? showId,
    String? torrentHash,
  }) {
    return LocalMediaFile(
      path: path,
      fileName: p.basename(path),
      sizeBytes: 2 * minPlayableBytes,
      modifiedDate: DateTime(2026, 1, 1),
      showName: showName,
      seasonNumber: season,
      episodeNumber: episode,
      showId: showId,
      extension: 'mkv',
      torrentHash: torrentHash,
    );
  }

  TorrentFile entry(
    String name, {
    double progress = 1,
    int index = 0,
    int size = 2 * minPlayableBytes,
    int priority = 1,
  }) {
    return TorrentFile(
      index: index,
      name: name,
      size: size,
      progress: progress,
      priority: priority,
      isSeed: false,
      availability: 1,
    );
  }

  // ── Harness ────────────────────────────────────────────────────────────

  /// Pumps a [ProviderScope] and hands back a real [WidgetRef] captured from a
  /// [Consumer].
  ///
  /// TMDB is signed out and both of its services **throw if anything reaches
  /// for them**, so a case that accidentally takes a network path fails
  /// loudly instead of hanging on a real HTTP call.
  Future<WidgetRef> pumpRef(
    WidgetTester tester, {
    TorrentListNotifier Function() torrents = _FakeTorrentList.new,
    _FakeEngine? engine,
    WatchProgressNotifier Function()? watchProgress,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          isTmdbSignedInProvider.overrideWithValue(false),
          tmdbAccountServiceProvider.overrideWith(
            (ref) =>
                throw StateError('TMDB account service must not be reached'),
          ),
          tmdbApiServiceProvider.overrideWith(
            (ref) => throw StateError('TMDB API service must not be reached'),
          ),
          localMediaFilesProvider.overrideWith(
            (ref) async => <LocalMediaFile>[],
          ),
          localMediaStreamProvider.overrideWith(
            (ref) => Stream<List<LocalMediaFile>>.value(const []),
          ),
          torrentListProvider.overrideWith(torrents),
          torrentEngineProvider.overrideWithValue(engine ?? _FakeEngine()),
          if (watchProgress != null)
            watchProgressProvider.overrideWith(watchProgress),
        ],
        child: Consumer(
          builder: (context, ref, child) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  WatchProgress? progressFor(WidgetRef ref, String path) =>
      ref.read(watchProgressProvider)[WatchProgress.generateHash(path)];

  /// A single-file torrent as the bundled engine reports it: saved straight
  /// into the download root, with that root as its content path too.
  Torrent rootSingleFile(String hash, String fileName) => _torrent(
    hash: hash,
    name: fileName,
    savePath: tmp.path,
    contentPath: tmp.path,
  );

  // ── Ownership ──────────────────────────────────────────────────────────

  group('which torrent a file belongs to', () {
    test('a torrent owns only the files its own list names', () {
      final t = _torrent(hash: 'a', savePath: '/dl', contentPath: '/dl');
      final file = entry('A.S01E01.mkv');
      expect(
        torrentFileIs(t, file, 1, '/dl/A.S01E01.mkv', path: p.posix),
        isTrue,
      );
      expect(
        torrentFileIs(t, file, 1, '/dl/B.S01E01.mkv', path: p.posix),
        isFalse,
        reason: 'same folder is not the same file',
      );
    });

    test('pack entries resolve under the save path', () {
      // qBittorrent: names carry the torrent's folder, relative to save_path.
      final t = _torrent(
        hash: 'pack',
        savePath: '/dl',
        contentPath: '/dl/Show.S01',
      );
      expect(
        torrentFilePath(t, entry('Show.S01/E05.mkv'), path: p.posix),
        '/dl/Show.S01/E05.mkv',
      );
    });

    test('Windows paths compare without regard to case or separator', () {
      final t = _torrent(
        hash: 'w',
        savePath: r'C:\Downloads',
        contentPath: r'C:\Downloads\Show.S01',
      );
      final file = entry(r'Show.S01\Episode.MKV');
      expect(
        torrentFileIs(
          t,
          file,
          2,
          r'c:\downloads\show.s01\episode.mkv',
          path: p.windows,
        ),
        isTrue,
      );
      expect(
        torrentFileIs(t, file, 2, '/downloads/show.s01/episode.mkv'),
        isFalse,
        reason: 'case matters on a case-sensitive filesystem',
      );
    });

    test("a torrent's folder is a candidate, a sibling folder is not", () {
      final inside = _torrent(
        hash: 'in',
        savePath: '/dl',
        contentPath: '/dl/Pack',
      );
      final elsewhere = _torrent(
        hash: 'out',
        savePath: '/other',
        contentPath: '/other/Pack',
      );
      final candidates = candidateTorrentsFor(
        [elsewhere, inside],
        '/dl/Pack/E01.mkv',
        path: p.posix,
      );
      expect(candidates.map((c) => c.torrent.hash), ['in']);
    });

    test('the file own hash is asked first', () {
      final a = _torrent(hash: 'a', savePath: '/dl', contentPath: '/dl');
      final b = _torrent(hash: 'b', savePath: '/dl', contentPath: '/dl');
      final candidates = candidateTorrentsFor(
        [a, b],
        '/dl/x.mkv',
        hintHash: 'b',
        path: p.posix,
      );
      expect(candidates.first.torrent.hash, 'b');
    });
  });

  // ── isFileCompleteOnDisk ───────────────────────────────────────────────

  group('isFileCompleteOnDisk', () {
    testWidgets('says no when the file is not on disk', (tester) async {
      final ref = await pumpRef(tester);
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(absent('gone.mkv'))),
      );
      expect(result, isFalse);
    });

    testWidgets('rejects a zero-byte placeholder', (tester) async {
      // 0 of 0 bytes is "100% downloaded" by every percentage an engine
      // reports. Size has to be checked before progress.
      final file = makeFile('placeholder.mkv', bytes: 0);
      final ref = await pumpRef(tester);
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse);
    });

    testWidgets('rejects anything below the playable floor', (tester) async {
      final file = makeFile('sample.mkv', bytes: minPlayableBytes - 1);
      final ref = await pumpRef(tester);
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse);
    });

    testWidgets('trusts the disk when no torrent lists the file', (
      tester,
    ) async {
      final file = makeFile('imported.mkv');
      final engine = _FakeEngine();
      final ref = await pumpRef(tester, engine: engine);
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue);
      expect(engine.requestedHashes, isEmpty, reason: 'no torrent to ask');
    });

    testWidgets('says no while its torrent is still downloading', (
      tester,
    ) async {
      final file = makeFile('partial.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () =>
            _FakeTorrentList(torrents: [rootSingleFile('h', 'partial.mkv')]),
        engine: _FakeEngine(
          files: {
            'h': [entry('partial.mkv', progress: 0.006)],
          },
        ),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse);
    });

    testWidgets('says yes when its torrent has every byte', (tester) async {
      final file = makeFile('done.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () =>
            _FakeTorrentList(torrents: [rootSingleFile('h', 'done.mkv')]),
        engine: _FakeEngine(
          files: {
            'h': [entry('done.mkv')],
          },
        ),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue);
    });

    testWidgets('99.9% is not complete for reading the file directly', (
      tester,
    ) async {
      // The missing tenth of a percent of a 4 GB episode is four megabytes,
      // usually the last ones — the seek index the player reads first.
      final file = makeFile('edge.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () =>
            _FakeTorrentList(torrents: [rootSingleFile('h', 'edge.mkv')]),
        engine: _FakeEngine(
          files: {
            'h': [entry('edge.mkv', progress: 0.999)],
          },
        ),
      );
      expect(
        await tester.runAsync(
          () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
        ),
        isFalse,
      );
    });

    testWidgets("reads the file's own torrent, not a neighbour in the root", (
      tester,
    ) async {
      // Two single-file torrents in the download root, both reporting the
      // root as their content path. The prefix test picked A for B's file,
      // found no B in A's list, "trusted the disk" — and handed the player
      // a 30% file of zeros.
      final b = makeFile('B.S01E01.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [
            rootSingleFile('a', 'A.S01E01.mkv'),
            rootSingleFile('b', 'B.S01E01.mkv'),
          ],
        ),
        engine: _FakeEngine(
          files: {
            'a': [entry('A.S01E01.mkv')],
            'b': [entry('B.S01E01.mkv', progress: 0.3)],
          },
        ),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(b.path)),
      );
      expect(result, isFalse);
    });

    testWidgets(
      'trusts the disk when the torrent beside it lists other files',
      (tester) async {
        final file = makeFile('unrelated.mkv');
        final ref = await pumpRef(
          tester,
          torrents: () =>
              _FakeTorrentList(torrents: [rootSingleFile('h', 'other.mkv')]),
          engine: _FakeEngine(
            files: {
              'h': [entry('other.mkv', progress: 0.1)],
            },
          ),
        );
        final result = await tester.runAsync(
          () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
        );
        expect(result, isTrue);
      },
    );

    testWidgets('fails closed when its likely torrent cannot be checked', (
      tester,
    ) async {
      // Being sent to the source picker for a file you already have is an
      // annoyance; being handed several hundred MB of zeros is a player that
      // spins forever with no error.
      final file = makeFile('unknown.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () =>
            _FakeTorrentList(torrents: [rootSingleFile('h', 'unknown.mkv')]),
        engine: _FakeEngine(throws: true),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse);
    });

    testWidgets("asks the file's own torrent hash first", (tester) async {
      final file = makeFile('tagged.mkv');
      final engine = _FakeEngine(
        files: {
          'from-file': [entry('tagged.mkv')],
        },
      );
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [
            rootSingleFile('from-scan', 'zzz.mkv'),
            rootSingleFile('from-file', 'tagged.mkv'),
          ],
        ),
        engine: engine,
      );
      await tester.runAsync(
        () => isFileCompleteOnDisk(
          ref,
          mediaFile(file.path, torrentHash: 'from-file'),
        ),
      );
      expect(engine.requestedHashes.first, 'from-file');
    });

    testWidgets('finds a file inside a multi-file torrent', (tester) async {
      final file = makeFile(p.join('Show.S01', 'E01.mkv'));
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [
            _torrent(
              hash: 'pack',
              savePath: tmp.path,
              contentPath: p.join(tmp.path, 'Show.S01'),
            ),
          ],
        ),
        engine: _FakeEngine(
          files: {
            'pack': [
              entry('Show.S01/E01.mkv', progress: 0.5),
              entry('Show.S01/E02.mkv', index: 1),
            ],
          },
        ),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse, reason: 'it matched E01, and E01 is at 50%');
    });

    testWidgets('ignores torrents with no paths', (tester) async {
      final file = makeFile('orphan.mkv');
      final engine = _FakeEngine();
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [_torrent(hash: 'blank', savePath: '', contentPath: '')],
        ),
        engine: engine,
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue, reason: 'nothing covers it, so trust the disk');
      expect(engine.requestedHashes, isEmpty);
    });
  });

  // ── planLibraryDelete ──────────────────────────────────────────────────

  group('planLibraryDelete', () {
    testWidgets('a file no torrent lists is a plain file delete', (
      tester,
    ) async {
      final file = makeFile('alone.mkv');
      final ref = await pumpRef(tester);
      expect(
        await tester.runAsync(
          () => planLibraryDelete(ref, mediaFile(file.path)),
        ),
        LibraryDeleteScope.fileOnly,
      );
    });

    testWidgets('a single-episode torrent goes whole', (tester) async {
      final file = makeFile('Show.S01E01.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [rootSingleFile('h', 'Show.S01E01.mkv')],
        ),
        engine: _FakeEngine(
          files: {
            'h': [entry('Show.S01E01.mkv')],
          },
        ),
      );
      expect(
        await tester.runAsync(
          () => planLibraryDelete(ref, mediaFile(file.path)),
        ),
        LibraryDeleteScope.wholeTorrent,
      );
    });

    testWidgets('one episode with its subtitles and sample still goes whole', (
      tester,
    ) async {
      final file = makeFile(p.join('Rel', 'Show.S01E01.mkv'));
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [
            _torrent(
              hash: 'h',
              savePath: tmp.path,
              contentPath: p.join(tmp.path, 'Rel'),
            ),
          ],
        ),
        engine: _FakeEngine(
          files: {
            'h': [
              entry('Rel/Show.S01E01.mkv'),
              entry('Rel/Show.S01E01.srt', index: 1, size: 50000),
              entry('Rel/sample.mkv', index: 2, size: 30 * minPlayableBytes),
            ],
          },
        ),
      );
      expect(
        await tester.runAsync(
          () => planLibraryDelete(ref, mediaFile(file.path)),
        ),
        LibraryDeleteScope.wholeTorrent,
      );
    });

    testWidgets('an episode of a season pack is deleted on its own', (
      tester,
    ) async {
      final file = makeFile(p.join('Pack', 'E02.mkv'));
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [
            _torrent(
              hash: 'pack',
              savePath: tmp.path,
              contentPath: p.join(tmp.path, 'Pack'),
            ),
          ],
        ),
        engine: _FakeEngine(files: {'pack': _pack()}),
      );
      expect(
        await tester.runAsync(
          () => planLibraryDelete(ref, mediaFile(file.path)),
        ),
        LibraryDeleteScope.fileInPack,
      );
    });

    testWidgets('a pack trimmed to this one episode goes whole', (
      tester,
    ) async {
      // How auto-download grabs from a pack: every other episode deselected
      // before it started. Nothing else in it is wanted.
      final file = makeFile(p.join('Pack', 'E02.mkv'));
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [
            _torrent(
              hash: 'pack',
              savePath: tmp.path,
              contentPath: p.join(tmp.path, 'Pack'),
            ),
          ],
        ),
        engine: _FakeEngine(
          files: {
            'pack': [
              entry('Pack/E01.mkv', priority: 0, progress: 0.02),
              entry('Pack/E02.mkv', index: 1),
              entry('Pack/E03.mkv', index: 2, priority: 0, progress: 0),
            ],
          },
        ),
      );
      expect(
        await tester.runAsync(
          () => planLibraryDelete(ref, mediaFile(file.path)),
        ),
        LibraryDeleteScope.wholeTorrent,
      );
    });
  });

  // ── deleteLibraryItem ──────────────────────────────────────────────────

  group('deleteLibraryItem', () {
    testWidgets('hands a single-file torrent to the engine whole', (
      tester,
    ) async {
      // The engine removes files more reliably than we can while it still
      // holds them open for seeding, so the direct delete must NOT also run.
      final file = makeFile('seeding.mkv');
      final torrents = _FakeTorrentList(
        torrents: [rootSingleFile('abc', 'seeding.mkv')],
      );
      final ref = await pumpRef(
        tester,
        torrents: () => torrents,
        engine: _FakeEngine(
          files: {
            'abc': [entry('seeding.mkv')],
          },
        ),
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(result!.success, isTrue);
      expect(result.fileRemoved, isTrue);
      expect(result.torrentRemoved, isTrue);
      expect(result.scope, LibraryDeleteScope.wholeTorrent);
      expect(torrents.deleteCalls, hasLength(1));
      expect(torrents.deleteCalls.single.hashes, ['abc']);
      expect(torrents.deleteCalls.single.deleteFiles, isTrue);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'the engine owns the removal; we must not race it',
      );
    });

    testWidgets("never deletes another torrent's files", (tester) async {
      // The data-loss bug. Two single-file torrents in the download root;
      // the user deletes library file B. The prefix match returned A —
      // whose torrent and files were deleted instead — and every retry
      // deleted another download.
      final a = makeFile('A.S01E01.mkv');
      final b = makeFile('B.S01E01.mkv');
      final torrents = _FakeTorrentList(
        torrents: [
          rootSingleFile('a', 'A.S01E01.mkv'),
          rootSingleFile('b', 'B.S01E01.mkv'),
        ],
      );
      final ref = await pumpRef(
        tester,
        torrents: () => torrents,
        engine: _FakeEngine(
          files: {
            'a': [entry('A.S01E01.mkv')],
            'b': [entry('B.S01E01.mkv')],
          },
        ),
      );

      await tester.runAsync(() => deleteLibraryItem(ref, mediaFile(b.path)));

      expect(torrents.deleteCalls.single.hashes, ['b']);
      expect(a.existsSync(), isTrue);
    });

    testWidgets('a file no torrent lists is deleted alone', (tester) async {
      // The other half of the same bug: an imported file sitting next to a
      // download took that download with it.
      final download = makeFile('A.S01E01.mkv');
      final imported = makeFile('Imported.mkv');
      final torrents = _FakeTorrentList(
        torrents: [rootSingleFile('a', 'A.S01E01.mkv')],
      );
      final ref = await pumpRef(
        tester,
        torrents: () => torrents,
        engine: _FakeEngine(
          files: {
            'a': [entry('A.S01E01.mkv')],
          },
        ),
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(imported.path)),
      );

      expect(result!.fileRemoved, isTrue);
      expect(result.torrentRemoved, isFalse);
      expect(result.scope, LibraryDeleteScope.fileOnly);
      expect(imported.existsSync(), isFalse);
      expect(torrents.deleteCalls, isEmpty);
      expect(download.existsSync(), isTrue);
    });

    testWidgets('one episode of a pack: deselected and deleted alone', (
      tester,
    ) async {
      final e1 = makeFile(p.join('Pack', 'E01.mkv'));
      final e2 = makeFile(p.join('Pack', 'E02.mkv'));
      final e3 = makeFile(p.join('Pack', 'E03.mkv'));
      final torrents = _FakeTorrentList(
        torrents: [
          _torrent(
            hash: 'pack',
            savePath: tmp.path,
            contentPath: p.join(tmp.path, 'Pack'),
          ),
        ],
      );
      final engine = _FakeEngine(files: {'pack': _pack()});
      final ref = await pumpRef(
        tester,
        torrents: () => torrents,
        engine: engine,
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(e2.path)),
      );

      expect(result!.fileRemoved, isTrue);
      expect(result.torrentRemoved, isFalse);
      expect(result.scope, LibraryDeleteScope.fileInPack);
      final deselect = engine.priorityCalls.single;
      expect(deselect.hash, 'pack');
      expect(deselect.ids, [1]);
      expect(deselect.priority, 0, reason: 'do not download');
      expect(torrents.deleteCalls, isEmpty, reason: 'the pack stays');
      expect(e2.existsSync(), isFalse);
      expect(e1.existsSync(), isTrue);
      expect(e3.existsSync(), isTrue);
    });

    testWidgets('deletes nothing when the engine will not deselect it', (
      tester,
    ) async {
      // Removing a file the torrent still wants only downloads it again.
      final e2 = makeFile(p.join('Pack', 'E02.mkv'));
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [
            _torrent(
              hash: 'pack',
              savePath: tmp.path,
              contentPath: p.join(tmp.path, 'Pack'),
            ),
          ],
        ),
        engine: _FakeEngine(files: {'pack': _pack()}, priorityResult: false),
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(e2.path)),
      );

      expect(result!.success, isFalse);
      expect(result.error, contains('season pack'));
      expect(e2.existsSync(), isTrue);
    });

    testWidgets('falls back to the file alone when the engine refuses', (
      tester,
    ) async {
      final file = makeFile('refused.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [rootSingleFile('abc', 'refused.mkv')],
          result: const TorrentActionResult.failure('engine said no'),
        ),
        engine: _FakeEngine(
          files: {
            'abc': [entry('refused.mkv')],
          },
        ),
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(result!.fileRemoved, isTrue);
      expect(
        result.torrentRemoved,
        isFalse,
        reason: 'the torrent is still in Transfers — say so',
      );
      expect(file.existsSync(), isFalse);
    });

    testWidgets('falls back to the file alone when the engine throws', (
      tester,
    ) async {
      final file = makeFile('threw.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [rootSingleFile('abc', 'threw.mkv')],
          throws: true,
        ),
        engine: _FakeEngine(
          files: {
            'abc': [entry('threw.mkv')],
          },
        ),
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(result!.fileRemoved, isTrue);
      expect(file.existsSync(), isFalse);
    });

    testWidgets('touches nothing but the target file', (tester) async {
      final target = makeFile('target.mkv');
      final sibling = makeFile('keep-me.mkv');
      final ref = await pumpRef(tester);

      await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(target.path)),
      );

      expect(target.existsSync(), isFalse);
      expect(sibling.existsSync(), isTrue);
    });

    testWidgets('is idempotent when the file is already gone', (tester) async {
      final ref = await pumpRef(tester);

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(absent('never-existed.mkv'))),
      );

      expect(result!.fileRemoved, isTrue);
      expect(result.error, isNull);
    });

    testWidgets('sweeps stale watch progress after a direct delete', (
      tester,
    ) async {
      final file = makeFile('watched.mkv');
      final ref = await pumpRef(tester);

      await tester.runAsync(
        () => ref
            .read(watchProgressProvider.notifier)
            .updateProgress(
              WatchProgress(
                fileHash: WatchProgress.generateHash(file.path),
                filePath: file.path,
                position: const Duration(minutes: 3),
                duration: const Duration(minutes: 45),
                lastWatched: DateTime(2026, 1, 1),
              ),
            ),
      );
      expect(progressFor(ref, file.path), isNotNull);

      await tester.runAsync(() => deleteLibraryItem(ref, mediaFile(file.path)));

      expect(
        progressFor(ref, file.path),
        isNull,
        reason: 'the file is gone and it was never finished',
      );
    });

    testWidgets('reports the file as removed even if the sweep fails', (
      tester,
    ) async {
      final file = makeFile('sweep-explodes.mkv');
      final ref = await pumpRef(
        tester,
        watchProgress: _ExplodingWatchProgress.new,
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(file.existsSync(), isFalse, reason: 'the unlink did happen');
      expect(result!.fileRemoved, isTrue);
      expect(result.error, isNull);
    });
  });

  // ── markAsWatched / markAsNotWatched, signed out ───────────────────────

  group('markAsWatched while signed out', () {
    testWidgets('creates an entry for a file that was never opened', (
      tester,
    ) async {
      final file = makeFile('fresh.mkv');
      final ref = await pumpRef(tester);

      await tester.runAsync(
        () => markAsWatched(
          ref,
          mediaFile(
            file.path,
            showName: 'Severance',
            season: 2,
            episode: 4,
            showId: 95396,
          ),
        ),
      );

      final entry = progressFor(ref, file.path);
      expect(entry, isNotNull);
      expect(entry!.isCompleted, isTrue);
      expect(entry.showName, 'Severance');
      expect(entry.showId, 95396);
      expect(entry.seasonNumber, 2);
      expect(entry.episodeNumber, 4);
      expect(entry.tmdbPushPending, isFalse, reason: 'nobody to tell');
    });

    testWidgets('marks a movie complete without resolving a movie id', (
      tester,
    ) async {
      // The TMDB overrides in [pumpRef] throw — so reaching for one fails.
      final file = makeFile('Dune Part Two 2024 1080p.mkv');
      final ref = await pumpRef(tester);

      await tester.runAsync(() => markAsWatched(ref, mediaFile(file.path)));

      final entry = progressFor(ref, file.path);
      expect(entry!.isCompleted, isTrue);
      expect(entry.movieId, isNull);
    });

    testWidgets('markAsNotWatched clears the flag it set', (tester) async {
      final file = makeFile('toggled.mkv');
      final ref = await pumpRef(tester);
      final item = mediaFile(
        file.path,
        showName: 'Andor',
        season: 1,
        episode: 6,
      );

      await tester.runAsync(() => markAsWatched(ref, item));
      expect(progressFor(ref, file.path)!.isCompleted, isTrue);

      await tester.runAsync(() => markAsNotWatched(ref, item));
      expect(progressFor(ref, file.path)!.isCompleted, isFalse);
    });
  });

  // ── reconcileWatchedWithTmdb ───────────────────────────────────────────

  group('reconcileWatchedWithTmdb', () {
    testWidgets('is a no-op while signed out', (tester) async {
      final ref = await pumpRef(tester);
      await expectLater(
        tester.runAsync(() => reconcileWatchedWithTmdb(ref)),
        completes,
      );
    });
  });

  // ── describeDeleteFailure ──────────────────────────────────────────────

  group('describeDeleteFailure', () {
    test('names the real cause of a Windows sharing violation', () {
      expect(
        describeDeleteFailure(
          const FileSystemException(
            'Deletion failed',
            'C:\\Downloads\\Show.mkv',
            OSError('The process cannot access the file', 32),
          ),
        ),
        'the file is still in use — stop the torrent and try again',
      );
    });

    test('covers the lock-violation code too', () {
      expect(
        describeDeleteFailure(
          const FileSystemException(
            'Deletion failed',
            'x',
            OSError('locked', 33),
          ),
        ),
        contains('still in use'),
      );
    });

    test('reports permission trouble plainly', () {
      // 1 EPERM, 5 ERROR_ACCESS_DENIED (Windows), 13 EACCES.
      for (final code in [1, 5, 13]) {
        expect(
          describeDeleteFailure(
            FileSystemException(
              'Deletion failed',
              'x',
              OSError('denied', code),
            ),
          ),
          'permission denied',
          reason: 'errno $code',
        );
      }
    });

    test('falls back to the OS message for anything else', () {
      expect(
        describeDeleteFailure(
          const FileSystemException(
            'Deletion failed',
            'x',
            OSError('No such file or directory', 2),
          ),
        ),
        'No such file or directory',
      );
    });

    test('never returns raw exception text or an empty string', () {
      expect(
        describeDeleteFailure(const FileSystemException('', 'x')),
        isNotEmpty,
      );
      final other = describeDeleteFailure(StateError('boom'));
      expect(other, isNotEmpty);
      expect(other, isNot(contains('StateError')));
    });
  });
}

/// Three real episodes in one pack folder, all selected.
List<TorrentFile> _pack() => [
  for (var i = 0; i < 3; i++)
    TorrentFile(
      index: i,
      name: 'Pack/E0${i + 1}.mkv',
      size: 2 * minPlayableBytes,
      progress: 1,
      priority: 1,
      isSeed: false,
      availability: 1,
    ),
];

Torrent _torrent({
  required String hash,
  String name = 'fixture',
  required String savePath,
  required String contentPath,
}) {
  return Torrent(
    hash: hash,
    name: name,
    size: 0,
    progress: 1,
    dlspeed: 0,
    upspeed: 0,
    eta: 0,
    state: 'stalledUP',
    numSeeds: 0,
    numLeeches: 0,
    ratio: 0,
    addedOn: 0,
    completionOn: 0,
    savePath: savePath,
    downloaded: 0,
    uploaded: 0,
    numComplete: 0,
    numIncomplete: 0,
    category: '',
    tags: '',
    priority: 0,
    amountLeft: 0,
    tracker: '',
    seenComplete: 0,
    lastActivity: 0,
    totalSize: 0,
    pieceSize: 0,
    piecesNum: 0,
    piecesHave: 0,
    contentPath: contentPath,
    sequentialDownload: false,
    firstLastPiecePriority: false,
  );
}

/// A [TorrentListNotifier] that never polls and answers deletes from a script.
class _FakeTorrentList extends TorrentListNotifier {
  _FakeTorrentList({
    this.torrents = const [],
    this.result = const TorrentActionResult.success(),
    this.throws = false,
  });

  final List<Torrent> torrents;
  final TorrentActionResult result;
  final bool throws;

  final List<({List<String> hashes, bool deleteFiles})> deleteCalls = [];

  @override
  TorrentListState build() => TorrentListState(torrents: torrents);

  @override
  Future<TorrentActionResult> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async {
    deleteCalls.add((hashes: hashes, deleteFiles: deleteFiles));
    if (throws) throw StateError('engine refused');
    return result;
  }
}

/// An engine that answers file lists and priority changes from a script and
/// records what it was asked.
class _FakeEngine extends QBittorrentApiService {
  _FakeEngine({
    this.files = const {},
    this.throws = false,
    this.priorityResult = true,
  });

  final Map<String, List<TorrentFile>> files;
  final bool throws;
  final bool priorityResult;
  final List<String> requestedHashes = [];
  final List<({String hash, List<int> ids, int priority})> priorityCalls = [];

  @override
  Future<List<TorrentFile>> getTorrentFiles(String hash) async {
    requestedHashes.add(hash);
    if (throws) throw StateError('engine unreachable');
    return files[hash] ?? const [];
  }

  @override
  Future<bool> setFilePriority(
    String hash,
    List<int> fileIds,
    int priority,
  ) async {
    priorityCalls.add((hash: hash, ids: fileIds, priority: priority));
    return priorityResult;
  }
}

/// A watch-progress notifier whose post-delete sweep fails.
class _ExplodingWatchProgress extends WatchProgressNotifier {
  @override
  Map<String, WatchProgress> build() => const {};

  @override
  Future<void> cleanupStaleEntries() async {
    throw StateError('sweep failed');
  }
}
