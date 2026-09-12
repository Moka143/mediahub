import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/torrent.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the library actions — the code that **deletes the user's files**
/// and reconciles watched state with TMDB.
///
/// This file closes a gap: every other service with a decision worth getting
/// wrong had a test, and this one — the only one that calls `File.delete()` —
/// had none. The cases concentrate on the two things that cost a user
/// something real when they misbehave:
///
///  * [deleteLibraryItem]'s fallback ladder. It prefers qBittorrent, which can
///    remove a file the seeding process still holds open, and drops to a direct
///    `File.delete()` only when qBit refuses. Getting the ladder wrong either
///    deletes nothing and says it worked, or races qBit for the same file.
///  * [isFileCompleteOnDisk]'s refusal to trust `existsSync()`. qBittorrent
///    pre-allocates the full length and zero-pads the remainder, so a 0.6% file
///    is present at full size and indistinguishable from a finished one by any
///    question the filesystem can answer.
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

  /// A file of [bytes] length, created sparsely so a "big enough to be real
  /// media" fixture costs no I/O. Deliberately the same shape as the
  /// qBittorrent pre-allocation the completeness check exists to see through.
  File makeFile(String name, {int bytes = 2 * minPlayableBytes}) {
    final file = File('${tmp.path}${Platform.pathSeparator}$name');
    final raf = file.openSync(mode: FileMode.write);
    if (bytes > 0) raf.truncateSync(bytes);
    raf.closeSync();
    return file;
  }

  String absent(String name) => '${tmp.path}${Platform.pathSeparator}$name';

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
      fileName: path.split(Platform.pathSeparator).last,
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

  Torrent torrent({required String hash, required String contentPath}) {
    return Torrent(
      hash: hash,
      name: 'fixture',
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
      savePath: '',
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

  TorrentFile torrentFile(String name, double progress) {
    return TorrentFile(
      index: 0,
      name: name,
      size: 2 * minPlayableBytes,
      progress: progress,
      priority: 1,
      isSeed: false,
      availability: 1,
    );
  }

  /// A torrent-list notifier seeded with one torrent covering [contentPath].
  TorrentListNotifier Function() covering(
    String contentPath, {
    String hash = 'abc',
  }) {
    return () => _FakeTorrentList(
      torrents: [torrent(hash: hash, contentPath: contentPath)],
    );
  }

  // ── Harness ────────────────────────────────────────────────────────────

  /// Pumps a [ProviderScope] and hands back a real [WidgetRef] captured from a
  /// [Consumer].
  ///
  /// The fixed overrides are as much assertion as setup: TMDB is signed out and
  /// both of its services **throw if anything reaches for them**, so a case
  /// that accidentally takes a network path fails loudly instead of hanging on
  /// a real HTTP call. The local mark is the source of truth and has to
  /// complete without a round-trip.
  Future<WidgetRef> pumpRef(
    WidgetTester tester, {
    TorrentListNotifier Function() torrents = _FakeTorrentList.new,
    QBittorrentApiService? qb,
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
          if (qb != null) torrentEngineProvider.overrideWithValue(qb),
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
      // 0 of 0 bytes is "100% downloaded" by every percentage qBittorrent
      // reports. Size has to be checked before progress, or such a file goes
      // straight to the player and mpv answers "Failed to recognize format".
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

    testWidgets('trusts the disk when no torrent covers the path', (
      tester,
    ) async {
      final file = makeFile('imported.mkv');
      final qb = _FakeQbApi();
      final ref = await pumpRef(tester, qb: qb);
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue);
      expect(qb.requestedHashes, isEmpty, reason: 'no torrent to ask about');
    });

    testWidgets('says no when the covering torrent is still downloading', (
      tester,
    ) async {
      final file = makeFile('partial.mkv');
      final ref = await pumpRef(
        tester,
        torrents: covering(file.path),
        qb: _FakeQbApi(files: [torrentFile('partial.mkv', 0.006)]),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse);
    });

    testWidgets('says yes when the covering torrent reports it complete', (
      tester,
    ) async {
      final file = makeFile('done.mkv');
      final ref = await pumpRef(
        tester,
        torrents: covering(file.path),
        qb: _FakeQbApi(files: [torrentFile('done.mkv', 1)]),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue);
    });

    testWidgets('treats 0.999 as complete and 0.998 as not', (tester) async {
      // The threshold is a float tolerance, not a business rule — qBittorrent
      // reports 0.9999… for finished files. Pin both sides so a tightening to
      // `== 1.0`, which would strand every finished torrent, fails here.
      final file = makeFile('edge.mkv');
      final ref = await pumpRef(
        tester,
        torrents: covering(file.path),
        qb: _FakeQbApi(files: [torrentFile('edge.mkv', 0.999)]),
      );
      expect(
        await tester.runAsync(
          () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
        ),
        isTrue,
      );

      final below = await pumpRef(
        tester,
        torrents: covering(file.path),
        qb: _FakeQbApi(files: [torrentFile('edge.mkv', 0.998)]),
      );
      expect(
        await tester.runAsync(
          () => isFileCompleteOnDisk(below, mediaFile(file.path)),
        ),
        isFalse,
      );
    });

    testWidgets('matches the torrent entry by basename, case-insensitively', (
      tester,
    ) async {
      // qBittorrent reports entries with the *host's* separator and its own
      // casing, so a Windows server yields `Season 01\Episode.mkv`.
      final file = makeFile('Episode.mkv');
      final ref = await pumpRef(
        tester,
        torrents: covering(file.path),
        qb: _FakeQbApi(files: [torrentFile(r'Season 01\EPISODE.MKV', 0.5)]),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse, reason: 'it matched, and the match says 50%');
    });

    testWidgets('trusts the disk when the torrent does not list the file', (
      tester,
    ) async {
      final file = makeFile('unrelated.mkv');
      final ref = await pumpRef(
        tester,
        torrents: covering(tmp.path),
        qb: _FakeQbApi(files: [torrentFile('something-else.mkv', 0.1)]),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue);
    });

    testWidgets('fails closed when the qBittorrent lookup throws', (
      tester,
    ) async {
      // Being sent to the source picker for a file you already have is an
      // annoyance; being handed several hundred MB of zeros is a player that
      // spins forever with no error.
      final file = makeFile('unknown.mkv');
      final ref = await pumpRef(
        tester,
        torrents: covering(file.path),
        qb: _FakeQbApi(throws: true),
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isFalse);
    });

    testWidgets('prefers the file own torrent hash over a path scan', (
      tester,
    ) async {
      final file = makeFile('tagged.mkv');
      final qb = _FakeQbApi(files: [torrentFile('tagged.mkv', 1)]);
      final ref = await pumpRef(
        tester,
        torrents: covering(file.path, hash: 'from-scan'),
        qb: qb,
      );
      await tester.runAsync(
        () => isFileCompleteOnDisk(
          ref,
          mediaFile(file.path, torrentHash: 'from-file'),
        ),
      );
      expect(qb.requestedHashes, ['from-file']);
    });

    testWidgets('matches a multi-file torrent by content-path prefix', (
      tester,
    ) async {
      final file = makeFile('inside-pack.mkv');
      final qb = _FakeQbApi(files: [torrentFile('inside-pack.mkv', 1)]);
      final ref = await pumpRef(
        tester,
        // Content path is the containing folder, not the file.
        torrents: covering(tmp.path, hash: 'pack'),
        qb: qb,
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue);
      expect(qb.requestedHashes, ['pack']);
    });

    testWidgets('ignores torrents with an empty content path', (tester) async {
      final file = makeFile('orphan.mkv');
      final qb = _FakeQbApi();
      final ref = await pumpRef(
        tester,
        torrents: covering('', hash: 'blank'),
        qb: qb,
      );
      final result = await tester.runAsync(
        () => isFileCompleteOnDisk(ref, mediaFile(file.path)),
      );
      expect(result, isTrue, reason: 'nothing covers it, so trust the disk');
      expect(qb.requestedHashes, isEmpty);
    });
  });

  // ── deleteLibraryItem ──────────────────────────────────────────────────

  group('deleteLibraryItem', () {
    testWidgets('delegates to qBittorrent when a torrent covers the file', (
      tester,
    ) async {
      // qBit removes files more reliably than we can while it still holds them
      // open for seeding, so the direct delete must NOT also run.
      final file = makeFile('seeding.mkv');
      final torrents = _FakeTorrentList(
        torrents: [torrent(hash: 'abc', contentPath: file.path)],
      );
      final ref = await pumpRef(tester, torrents: () => torrents);

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(result!.success, isTrue);
      expect(result.fileRemoved, isTrue);
      expect(result.torrentRemoved, isTrue);
      // Field-by-field: a record's `==` compares its `List` field by
      // identity, so a whole-record match never holds here.
      expect(torrents.deleteCalls, hasLength(1));
      expect(torrents.deleteCalls.single.hashes, ['abc']);
      expect(torrents.deleteCalls.single.deleteFiles, isTrue);
      expect(
        file.existsSync(),
        isTrue,
        reason: 'qBittorrent owns the removal; we must not race it',
      );
    });

    testWidgets('falls back to a direct delete when qBittorrent refuses', (
      tester,
    ) async {
      final file = makeFile('refused.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [torrent(hash: 'abc', contentPath: file.path)],
          result: const TorrentActionResult.failure('qBittorrent said no'),
        ),
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(result!.fileRemoved, isTrue);
      expect(result.torrentRemoved, isTrue, reason: 'a torrent did cover it');
      expect(file.existsSync(), isFalse);
    });

    testWidgets('falls back to a direct delete when qBittorrent throws', (
      tester,
    ) async {
      final file = makeFile('threw.mkv');
      final ref = await pumpRef(
        tester,
        torrents: () => _FakeTorrentList(
          torrents: [torrent(hash: 'abc', contentPath: file.path)],
          throws: true,
        ),
      );

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(result!.fileRemoved, isTrue);
      expect(file.existsSync(), isFalse);
    });

    testWidgets('deletes directly when no torrent covers the file', (
      tester,
    ) async {
      final file = makeFile('standalone.mkv');
      final torrents = _FakeTorrentList();
      final ref = await pumpRef(tester, torrents: () => torrents);

      final result = await tester.runAsync(
        () => deleteLibraryItem(ref, mediaFile(file.path)),
      );

      expect(result!.fileRemoved, isTrue);
      expect(result.torrentRemoved, isFalse);
      expect(file.existsSync(), isFalse);
      expect(torrents.deleteCalls, isEmpty);
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
      // Reached whenever the user deletes twice, or qBittorrent removed the
      // file between the library scan and the click. It must not throw.
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

      // A part-watched entry for the file we are about to delete. The sweep
      // drops entries whose file is gone and that were never finished.
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
      // The sweep runs *after* the unlink, so folding its failure into the
      // delete result told the user "nothing was removed" about a file that
      // was in fact already gone — and the row disappeared anyway.
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
      // The bug behind "menu actions don't work": with no pre-existing
      // WatchProgress row, Mark as watched silently no-opped.
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
    });

    testWidgets('marks a movie complete without resolving a movie id', (
      tester,
    ) async {
      // Resolution is gated on being signed in, and the TMDB overrides in
      // [pumpRef] throw — so reaching for one fails this test.
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
      // Guarded before the account service is read — which is exactly what the
      // throwing override in [pumpRef] asserts.
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
      // The one users actually hit: qBittorrent holds every file it is
      // seeding, and Windows — unlike macOS and Linux — refuses to unlink an
      // open file. The raw exception reads "OSError: The process cannot
      // access the file because it is being used by another process,
      // errno = 32", which says nothing about what to do.
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

    test('never returns an empty string', () {
      expect(
        describeDeleteFailure(const FileSystemException('', 'x')),
        isNotEmpty,
      );
      expect(describeDeleteFailure(StateError('boom')), isNotEmpty);
    });
  });
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
    if (throws) throw StateError('qBittorrent refused');
    return result;
  }
}

/// A [QBittorrentApiService] that answers `getTorrentFiles` from a script and
/// records which hashes it was asked about.
class _FakeQbApi extends QBittorrentApiService {
  _FakeQbApi({this.files = const [], this.throws = false});

  final List<TorrentFile> files;
  final bool throws;
  final List<String> requestedHashes = [];

  @override
  Future<List<TorrentFile>> getTorrentFiles(String hash) async {
    requestedHashes.add(hash);
    if (throws) throw StateError('qBittorrent unreachable');
    return files;
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
