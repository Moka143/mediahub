import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/stream_request.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/services/streaming/file_selection.dart';
import 'package:mediahub/services/streaming/video_file_locator.dart';
import 'package:mediahub/services/streaming_service.dart';
import 'package:mediahub/services/torrent_engine.dart';
import 'package:path/path.dart' as p;

const _hash = 'abcdef0123456789abcdef0123456789abcdef01';

TorrentFile _file(
  int index,
  String name, {
  int size = 100,
  double progress = 0,
  int priority = 1,
}) => TorrentFile(
  index: index,
  name: name,
  size: size,
  progress: progress,
  priority: priority,
  isSeed: false,
  availability: 0,
);

Torrent _torrent({
  String savePath = '/downloads',
  String contentPath = '/downloads/Show',
  double progress = 0,
  String state = 'downloading',
  bool sequential = true,
}) => Torrent(
  hash: _hash,
  name: 'Show',
  size: 0,
  progress: progress,
  dlspeed: 0,
  upspeed: 0,
  eta: 0,
  state: state,
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
  sequentialDownload: sequential,
  firstLastPiecePriority: false,
);

StreamRequest _pack({int? fileIdx}) => StreamRequest(
  displayName: 'Show.S01.1080p',
  magnetUri: 'magnet:?xt=urn:btih:$_hash',
  infoHash: _hash,
  fileIdx: fileIdx,
  isSingleFile: false,
  isSeasonPack: true,
);

/// An engine scripted by the test. Applies file priorities to its own file
/// list, so a second session sees what the first one did.
class _FakeEngine extends TorrentEngine {
  _FakeEngine({required this.files, this.torrentPresentBeforeAdd = false})
    : _listed = torrentPresentBeforeAdd;

  final bool torrentPresentBeforeAdd;
  bool _listed;

  /// What the engine reports. [silent] makes every listing fail.
  List<TorrentFile> files;
  Torrent torrent = _torrent();
  bool silent = false;
  int pieceSize = 0;
  List<int>? pieceStates;
  String? engineStreamUrl;

  /// Each call as (comma-joined file ids, priority).
  final List<(String, int)> priorityCalls = [];

  @override
  EngineCapabilities get capabilities =>
      const EngineCapabilities(pieceLevelControl: false);

  @override
  String get baseUrl => 'http://fake';

  @override
  Future<bool> login() async => true;

  @override
  Future<bool> testConnection() async => true;

  @override
  Future<String?> getVersion() async => 'fake';

  @override
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes}) async {
    if (silent) return null;
    return _listed ? [torrent] : [];
  }

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async =>
      silent ? null : files;

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    bool? paused,
    bool? sequentialDownload,
  }) async {
    _listed = true;
    return true;
  }

  @override
  Future<bool> pauseTorrents(List<String> hashes) async => true;

  @override
  Future<bool> resumeTorrents(List<String> hashes) async => true;

  @override
  Future<bool> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async => true;

  @override
  Future<bool> setFilePriority(
    String hash,
    List<int> fileIds,
    int priority,
  ) async {
    priorityCalls.add((fileIds.join(','), priority));
    files = [
      for (final f in files)
        fileIds.contains(f.index)
            ? _file(
                f.index,
                f.name,
                size: f.size,
                progress: f.progress,
                priority: priority,
              )
            : f,
    ];
    return true;
  }

  @override
  String? streamUrl(String hash, int fileIndex) => engineStreamUrl;

  @override
  Future<List<int>?> getPieceStates(String hash) async => pieceStates;

  @override
  Future<int> getPieceSize(String hash) async => pieceSize;

  @override
  void dispose() {}
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met in time');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

StreamingService _service(
  _FakeEngine engine, {
  Duration metadataTimeout = StreamingService.defaultMetadataTimeout,
  Duration engineSilenceLimit = StreamingService.defaultEngineSilenceLimit,
}) {
  final service = StreamingService(
    engine,
    metadataTimeout: metadataTimeout,
    engineSilenceLimit: engineSilenceLimit,
    pollingInterval: const Duration(milliseconds: 20),
  );
  addTearDown(service.dispose);
  return service;
}

void main() {
  group('selectStreamFile', () {
    final pack = [
      _file(0, 'Show/Show.S01E01.mkv'),
      _file(1, 'Show/Show.S01E10.mkv'),
      _file(2, 'Show/Show.S01E02.mkv', size: 500),
      _file(3, 'Show/sample.txt', size: 9000),
    ];

    test('uses the index the indexer gave', () {
      expect(selectStreamFile(request: _pack(fileIdx: 2), files: pack), 2);
    });

    test('S01E01 does not pick S01E10', () {
      // The old episode pattern had no end boundary.
      final reversed = [pack[1], pack[0]];
      expect(
        selectStreamFile(
          request: _pack(),
          files: reversed,
          season: 1,
          episode: 1,
        ),
        1,
      );
    });

    test('falls back to the largest video, never a non-video', () {
      expect(selectStreamFile(request: _pack(), files: pack), 2);
    });

    test('matches the indexer file name exactly, not by substring', () {
      final request = StreamRequest(
        displayName: 'x',
        magnetUri: 'magnet:',
        infoHash: _hash,
        filename: 'Show.S01E01.mkv',
        isSingleFile: false,
        isSeasonPack: true,
      );
      expect(selectStreamFile(request: request, files: pack), 0);
    });

    test('a torrent with no video has nothing to stream', () {
      expect(
        selectStreamFile(request: _pack(), files: [_file(0, 'readme.txt')]),
        isNull,
      );
    });
  });

  group('trimming a season pack', () {
    test('never deselects a file another session is playing', () {
      final files = [
        _file(0, 'E01.mkv'),
        _file(1, 'E02.mkv'),
        _file(2, 'E03.mkv'),
      ];
      expect(filesToDeselect(files: files, target: 1, protectedIndexes: {0}), [
        2,
      ]);
    });

    test('leaves finished and already-deselected files alone', () {
      final files = [
        _file(0, 'E01.mkv', progress: 1.0),
        _file(1, 'E02.mkv'),
        _file(2, 'E03.mkv', priority: 0),
        _file(3, 'E04.mkv'),
      ];
      expect(filesToDeselect(files: files, target: 1), [3]);
    });

    test('a pack queued in full before the session is not trimmed', () {
      final queued = [_file(0, 'E01.mkv'), _file(1, 'E02.mkv')];
      expect(mayTrimTorrent(addedBySession: false, files: queued), isFalse);
      expect(mayTrimTorrent(addedBySession: true, files: queued), isTrue);
      expect(
        mayTrimTorrent(
          addedBySession: false,
          files: [_file(0, 'E01.mkv'), _file(1, 'E02.mkv', priority: 0)],
        ),
        isTrue,
        reason: 'already managed file by file',
      );
    });
  });

  group('locating the video on disk', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mediahub_locate');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<String> touch(String relative) async {
      final file = File(p.joinAll([tmp.path, ...relative.split('/')]));
      await file.create(recursive: true);
      await file.writeAsBytes(List.filled(16, 1));
      return file.path;
    }

    test('joins the save path, not the content path, with the file name', () {
      expect(
        torrentFilePath('/save', 'Show/Season 2/E01.mkv'),
        p.join('/save', 'Show', 'Season 2', 'E01.mkv'),
      );
      expect(
        torrentFilePath('/save', r'Show\Season 2\E01.mkv'),
        p.join('/save', 'Show', 'Season 2', 'E01.mkv'),
      );
    });

    test('finds S02E01, not the S01E01 with the same file name', () async {
      // qBittorrent's content path is <save>/<root>; joining the file name
      // (which starts with <root>/) onto it doubled the root, missed, and the
      // name-only fallback picked the first "Episode 01.mkv" in the pack.
      await touch('Show/Season 1/Episode 01.mkv');
      final want = await touch('Show/Season 2/Episode 01.mkv');

      final located = await locateTorrentFile(
        savePath: tmp.path,
        contentPath: p.join(tmp.path, 'Show'),
        nameInTorrent: 'Show/Season 2/Episode 01.mkv',
        torrentHash: _hash,
      );
      expect(located.exists, isTrue);
      expect(located.file.path, want);
      expect(located.file.torrentHash, _hash);
    });

    test('a missing file is reported missing, not guessed', () async {
      await touch('Show/Season 1/Episode 01.mkv');
      await touch('Show/Season 2/Episode 01.mkv');

      final located = await locateTorrentFile(
        savePath: tmp.path,
        contentPath: p.join(tmp.path, 'Show'),
        nameInTorrent: 'Show/Season 3/Episode 01.mkv',
      );
      expect(located.exists, isFalse);
    });

    test('an unambiguous file elsewhere under the torrent is found', () async {
      final want = await touch('Show/Episode 05.mkv');
      final located = await locateTorrentFile(
        savePath: tmp.path,
        contentPath: p.join(tmp.path, 'Show'),
        nameInTorrent: 'Other/Episode 05.mkv',
      );
      expect(located.exists, isTrue);
      expect(located.file.path, want);
    });
  });

  group('StreamingService', () {
    test('a magnet whose metadata never arrives fails, and says why', () async {
      // qBittorrent lists a magnet at once, with no files, until metadata
      // arrives. The timeout used to apply only while the torrent was not
      // listed at all, so this spun on "Preparing…" for ever.
      final engine = _FakeEngine(files: const []);
      final service = _service(
        engine,
        metadataTimeout: const Duration(milliseconds: 120),
      );

      final session = await service.startStreamingRequest(request: _pack());
      await _until(
        () => service.getSession(session.id)?.state == StreamingState.error,
      );
      expect(
        service.getSession(session.id)!.errorMessage,
        contains("Couldn't get this torrent's details"),
      );
    });

    test('a short engine outage does not fail a healthy session', () async {
      final engine = _FakeEngine(
        files: [_file(0, 'Show/E01.mkv', size: 1000, progress: 0.1)],
      );
      final service = _service(
        engine,
        engineSilenceLimit: const Duration(milliseconds: 400),
      );

      final session = await service.startStreamingRequest(request: _pack());
      await _until(
        () => service.getSession(session.id)?.state == StreamingState.buffering,
      );

      engine.silent = true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        service.getSession(session.id)!.state,
        StreamingState.buffering,
        reason: 'one failed poll is not "the torrent is gone"',
      );

      await _until(
        () => service.getSession(session.id)?.state == StreamingState.error,
      );
      expect(
        service.getSession(session.id)!.errorMessage,
        contains('stopped responding'),
      );
    });

    test('selects the target before deselecting the rest', () async {
      // rqbit refuses a selection with nothing in it; deselecting first could
      // leave nothing selected and be refused outright.
      final engine = _FakeEngine(
        files: [
          _file(0, 'Show/E01.mkv'),
          _file(1, 'Show/E02.mkv'),
          _file(2, 'Show/E03.mkv'),
        ],
      );
      final service = _service(engine);

      final session = await service.startStreamingRequest(
        request: _pack(fileIdx: 1),
      );
      await _until(
        () => service.getSession(session.id)?.state == StreamingState.buffering,
      );
      expect(engine.priorityCalls.first, ('1', 7));
      expect(engine.priorityCalls[1], ('0,2', 0));
    });

    test(
      'a prefetch from the same pack leaves the playing episode alone',
      () async {
        final engine = _FakeEngine(
          files: [
            _file(0, 'Show/E05.mkv'),
            _file(1, 'Show/E06.mkv'),
            _file(2, 'Show/E07.mkv'),
          ],
        );
        final service = _service(engine);

        final playing = await service.startStreamingRequest(
          request: _pack(fileIdx: 0),
        );
        await _until(
          () =>
              service.getSession(playing.id)?.state == StreamingState.buffering,
        );
        // E06 and E07 were deselected for E05. The next-episode prefetch
        // now asks for E06 out of the same pack.
        engine.priorityCalls.clear();

        final next = await service.startStreamingRequest(
          request: _pack(fileIdx: 1),
          allowSlowBuffer: true,
        );
        await _until(
          () => service.getSession(next.id)?.state == StreamingState.buffering,
        );

        expect(engine.priorityCalls, isNotEmpty);
        for (final (ids, priority) in engine.priorityCalls) {
          if (priority == 0) {
            expect(
              ids.split(','),
              isNot(contains('0')),
              reason: 'E05 is still playing',
            );
          }
        }
        expect(
          engine.files[0].priority,
          greaterThan(0),
          reason: 'E05 must keep downloading',
        );
      },
    );

    test('a pack the user queued in full is not trimmed', () async {
      final engine = _FakeEngine(
        files: [_file(0, 'Show/E01.mkv'), _file(1, 'Show/E02.mkv')],
        torrentPresentBeforeAdd: true,
      );
      final service = _service(engine);

      final session = await service.startStreamingRequest(
        request: _pack(fileIdx: 1),
      );
      await _until(
        () => service.getSession(session.id)?.state == StreamingState.buffering,
      );
      expect(engine.priorityCalls, [('1', 7)]);
    });

    test('a finished file goes ready straight from disk', () async {
      final tmp = await Directory.systemTemp.createTemp('mediahub_ready');
      addTearDown(() => tmp.delete(recursive: true));
      final onDisk = File(p.join(tmp.path, 'Show', 'E01.mkv'));
      await onDisk.create(recursive: true);
      await onDisk.writeAsBytes(List.filled(32, 1));

      final engine = _FakeEngine(
        files: [_file(0, 'Show/E01.mkv', size: 32, progress: 1.0)],
      )..torrent = _torrent(savePath: tmp.path, contentPath: tmp.path);
      final service = _service(engine);

      final session = await service.startStreamingRequest(
        request: _pack(fileIdx: 0),
      );
      await _until(
        () => service.getSession(session.id)?.state == StreamingState.ready,
      );
      final ready = service.getSession(session.id)!;
      expect(ready.streamUrl, isNull, reason: 'read from disk');
      expect(ready.videoFile?.path, onDisk.path);
    });

    test(
      'a finished file that is not on disk fails instead of going ready',
      () async {
        final engine = _FakeEngine(
          files: [_file(0, 'Show/E01.mkv', size: 32, progress: 1.0)],
        )..torrent = _torrent(savePath: '/nonexistent/mediahub-test');
        final service = _service(engine);

        final session = await service.startStreamingRequest(
          request: _pack(fileIdx: 0),
        );
        await _until(
          () => service.getSession(session.id)?.state == StreamingState.error,
        );
        expect(
          service.getSession(session.id)!.errorMessage,
          contains("Couldn't find the video file"),
        );
      },
    );

    test(
      'an engine stream goes ready once the head of the file is down',
      () async {
        final engine =
            _FakeEngine(
                files: [_file(0, 'Show/E01.mkv', size: 8, progress: 0.5)],
              )
              ..pieceSize = 4
              ..pieceStates = [2, 0]
              ..engineStreamUrl = 'http://fake/stream/0';
        final service = _service(engine);

        final session = await service.startStreamingRequest(
          request: _pack(fileIdx: 0),
        );
        await _until(
          () => service.getSession(session.id)?.state == StreamingState.ready,
        );
        expect(
          service.getSession(session.id)!.streamUrl,
          'http://fake/stream/0',
        );
      },
    );

    test('cancelling stops the session for good', () async {
      final engine = _FakeEngine(files: const []);
      final service = _service(engine);
      final session = await service.startStreamingRequest(request: _pack());
      await service.cancelSession(session.id);
      expect(service.getSession(session.id), isNull);
    });
  });
}
