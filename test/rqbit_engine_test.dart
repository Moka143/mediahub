import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/rqbit_engine.dart';
import 'package:mediahub/utils/constants.dart';

/// A realistic `GET /torrents?with_stats=true` entry, shaped exactly as rqbit
/// serialises it: `state` flattened to a string, speeds in MiB/s under a
/// `mbps` key, and a Rust `Duration` as `{secs, nanos}`.
Map<String, dynamic> _entry({
  String state = 'live',
  bool finished = false,
  bool initializingPaused = false,
  int livePeers = 4,
  int progressBytes = 500 * 1024 * 1024,
  int totalBytes = 1000 * 1024 * 1024,
  bool withLive = true,
}) {
  return {
    'id': 1,
    'info_hash': 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
    'name': 'Some.Show.S01E01.1080p.mkv',
    'output_folder': '/downloads',
    'total_pieces': 1000,
    'stats': {
      'state': state,
      if (state == 'initializing') 'initializing_paused': initializingPaused,
      'file_progress': [progressBytes],
      'error': null,
      'progress_bytes': progressBytes,
      'uploaded_bytes': 100 * 1024 * 1024,
      'total_bytes': totalBytes,
      'finished': finished,
      'live': withLive
          ? {
              'snapshot': {
                'downloaded_and_checked_bytes': progressBytes,
                'fetched_bytes': progressBytes,
                'uploaded_bytes': 100 * 1024 * 1024,
                'downloaded_and_checked_pieces': 500,
                'total_piece_download_ms': 1000,
                'peer_stats': {
                  'queued': 2,
                  'connecting': 1,
                  'live': livePeers,
                  'seen': 42,
                  'dead': 3,
                  'not_needed': 0,
                },
              },
              'download_speed': {'mbps': 2.5, 'human_readable': '2.50 MiB/s'},
              'upload_speed': {'mbps': 0.5, 'human_readable': '0.50 MiB/s'},
              'time_remaining': {
                'duration': {'secs': 200, 'nanos': 0},
                'human_readable': '3m 20s',
              },
            }
          : null,
    },
  };
}

void main() {
  group('mapState', () {
    // The mapping's job is not to produce a pretty string — it is to keep
    // TorrentState's predicates answering correctly, because the Transfers
    // screen's filters, colours and the auto-download reconciler all read
    // those rather than the raw string.
    String map(
      String state, {
      bool finished = false,
      bool initializingPaused = false,
      bool hasPeers = true,
    }) => RqbitEngine.mapState(
      state: state,
      finished: finished,
      initializingPaused: initializingPaused,
      hasPeers: hasPeers,
    );

    test('a live unfinished torrent with peers is downloading', () {
      final s = map('live');
      expect(s, TorrentState.downloading);
      expect(TorrentState.isDownloading(s), isTrue);
      expect(TorrentState.isCompleted(s), isFalse);
    });

    test('a live torrent with no peers is stalled, not downloading-at-0', () {
      // qBittorrent distinguishes these and the UI colours them differently;
      // rqbit has only "live", so the peer count is what carries the
      // difference across.
      final s = map('live', hasPeers: false);
      expect(s, TorrentState.stalledDL);
      expect(TorrentState.isDownloading(s), isTrue);
    });

    test('a finished live torrent is seeding', () {
      final s = map('live', finished: true);
      expect(s, TorrentState.uploading);
      expect(TorrentState.isSeeding(s), isTrue);
      expect(TorrentState.isCompleted(s), isTrue);
    });

    test('initializing is metadata download', () {
      final s = map('initializing');
      expect(s, TorrentState.metaDL);
      expect(TorrentState.isDownloading(s), isTrue);
    });

    test('initializing-while-paused reads as paused, not as metaDL', () {
      final s = map('initializing', initializingPaused: true);
      expect(s, TorrentState.pausedDL);
      expect(TorrentState.isPaused(s), isTrue);
    });

    test('paused splits on whether the torrent finished', () {
      expect(TorrentState.isPaused(map('paused')), isTrue);
      expect(map('paused'), TorrentState.pausedDL);

      final done = map('paused', finished: true);
      expect(done, TorrentState.pausedUP);
      expect(TorrentState.isPaused(done), isTrue);
      expect(TorrentState.isCompleted(done), isTrue);
    });

    test('error maps to error', () {
      expect(TorrentState.hasError(map('error')), isTrue);
    });

    test('an unrecognised state degrades instead of throwing', () {
      // rqbit adding a state must not crash the Transfers screen.
      final s = map('teleporting');
      expect(s, TorrentState.unknown);
      expect(TorrentState.isDownloading(s), isFalse);
      expect(TorrentState.hasError(s), isFalse);
    });
  });

  group('mibPerSecondToBytes', () {
    test('converts MiB/s to bytes/s', () {
      expect(RqbitEngine.mibPerSecondToBytes(1), 1024 * 1024);
      expect(RqbitEngine.mibPerSecondToBytes(2.5), 2621440);
    });

    test('a missing speed is zero, not a crash', () {
      expect(RqbitEngine.mibPerSecondToBytes(null), 0);
    });
  });

  group('torrentFromJson', () {
    test('maps a live torrent into the app\'s shape', () {
      final t = RqbitEngine.torrentFromJson(_entry());

      expect(t.hash, 'abcdef0123456789abcdef0123456789abcdef01');
      expect(t.name, 'Some.Show.S01E01.1080p.mkv');
      expect(t.progress, closeTo(0.5, 1e-9));
      expect(t.size, 1000 * 1024 * 1024);
      expect(t.dlspeed, 2621440);
      expect(t.upspeed, 524288);
      expect(t.eta, 200);
      expect(t.state, TorrentState.downloading);
      expect(t.savePath, '/downloads');
      // rqbit's output_folder is already the torrent's own folder, so it is
      // the content root — not a parent to join the name onto.
      expect(t.contentPath, '/downloads');
      expect(t.piecesNum, 1000);
      expect(t.amountLeft, 500 * 1024 * 1024);
    });

    test('hashes are lower-cased so indexer casing cannot split a torrent', () {
      // Torrentio and EZTV hand back upper-case hashes; every lookup in the
      // app compares against what the engine reported.
      final t = RqbitEngine.torrentFromJson(_entry());
      expect(t.hash, equals(t.hash.toLowerCase()));
    });

    test('sequentialDownload is true — ordering is the engine\'s job', () {
      // The streaming path reads this flag to decide a torrent is stream-ready.
      expect(RqbitEngine.torrentFromJson(_entry()).sequentialDownload, isTrue);
    });

    test('connected peers become numSeeds, swarm size becomes numComplete', () {
      final t = RqbitEngine.torrentFromJson(_entry(livePeers: 7));
      expect(t.numSeeds, 7);
      expect(t.numComplete, 42);
    });

    test('a torrent with no live stats does not crash and has no ETA', () {
      // `live` is null for paused and initializing torrents — the common case
      // right after an add, which is exactly when the UI first renders one.
      final t = RqbitEngine.torrentFromJson(
        _entry(state: 'paused', withLive: false),
      );
      expect(t.dlspeed, 0);
      expect(t.upspeed, 0);
      expect(t.eta, 8640000, reason: "qBittorrent's sentinel for unknown");
      expect(t.state, TorrentState.pausedDL);
    });

    test('an entry with no stats at all still yields a usable torrent', () {
      // `?with_stats=true` is always sent, but a torrent can appear in the
      // list before its stats exist.
      final t = RqbitEngine.torrentFromJson({
        'info_hash': 'aabb',
        'name': 'x',
        'output_folder': '/d',
      });
      expect(t.progress, 0);
      expect(t.size, 0);
      expect(t.state, TorrentState.metaDL);
    });

    test('a zero-byte total does not divide by zero', () {
      final t = RqbitEngine.torrentFromJson(
        _entry(totalBytes: 0, progressBytes: 0),
      );
      expect(t.progress, 0);
    });
  });

  group('expandBitfield', () {
    test('reads bits most-significant-first, as the wire protocol does', () {
      // 0b10100000 → pieces 0 and 2 present.
      expect(RqbitEngine.expandBitfield([0xA0], 8), [2, 0, 2, 0, 0, 0, 0, 0]);
    });

    test('stops at the piece count rather than the byte boundary', () {
      // A 10-piece torrent occupies 2 bytes; the trailing 6 bits are padding
      // and must not be reported as pieces.
      final states = RqbitEngine.expandBitfield([0xFF, 0xC0], 10);
      expect(states, hasLength(10));
      expect(states.every((s) => s == 2), isTrue);
    });

    test('a short body leaves the rest missing instead of throwing', () {
      final states = RqbitEngine.expandBitfield([0xFF], 16);
      expect(states, hasLength(16));
      expect(states.take(8).every((s) => s == 2), isTrue);
      expect(states.skip(8).every((s) => s == 0), isTrue);
    });

    test('an empty bitfield yields all-missing', () {
      expect(RqbitEngine.expandBitfield(const [], 4), [0, 0, 0, 0]);
    });
  });

  group('derivePieceSize', () {
    test('recovers the piece length for an ordinary torrent', () {
      const size = 4 * 1024 * 1024;
      const pieces = 250;
      final total = size * (pieces - 1) + 1234;
      expect(
        RqbitEngine.derivePieceSize(totalBytes: total, pieces: pieces),
        size,
      );
    });

    test('survives the case plain division gets wrong', () {
      // A final piece of one byte. `ceil(total / pieces)` answers 3774874 here
      // — off by more than 400 KB, and every piece-to-byte-offset conversion
      // after it would land inside the wrong piece.
      const size = 4 * 1024 * 1024;
      const pieces = 10;
      final total = size * (pieces - 1) + 1;
      expect((total + pieces - 1) ~/ pieces, isNot(size));
      expect(
        RqbitEngine.derivePieceSize(totalBytes: total, pieces: pieces),
        size,
      );
    });

    test('recovers a small piece length too', () {
      const size = 256 * 1024;
      const pieces = 4096;
      final total = size * pieces;
      expect(
        RqbitEngine.derivePieceSize(totalBytes: total, pieces: pieces),
        size,
      );
    });

    test('answers 0 — "unknown" — rather than guessing when ambiguous', () {
      // One piece holding a handful of bytes fits every candidate size.
      expect(RqbitEngine.derivePieceSize(totalBytes: 10, pieces: 1), 0);
    });

    test('answers 0 for nonsense input', () {
      expect(RqbitEngine.derivePieceSize(totalBytes: 0, pieces: 10), 0);
      expect(RqbitEngine.derivePieceSize(totalBytes: 100, pieces: 0), 0);
      expect(RqbitEngine.derivePieceSize(totalBytes: -1, pieces: -1), 0);
    });
  });

  group('wantsCustomOutputFolder', () {
    // rqbit writes straight into an explicit `output_folder` with no
    // per-torrent subfolder, so sending the session default on every add
    // would flatten every torrent into one directory — two season packs
    // would overwrite each other's files. Only a genuinely different path
    // should be sent.
    test('no override when the caller asked for nothing', () {
      expect(RqbitEngine.wantsCustomOutputFolder(null, '/downloads'), isFalse);
      expect(RqbitEngine.wantsCustomOutputFolder('', '/downloads'), isFalse);
    });

    test('no override when the caller asked for the default', () {
      expect(
        RqbitEngine.wantsCustomOutputFolder('/downloads', '/downloads'),
        isFalse,
      );
    });

    test('no override for a differently-spelt default', () {
      expect(
        RqbitEngine.wantsCustomOutputFolder('/downloads/', '/downloads'),
        isFalse,
      );
      expect(
        RqbitEngine.wantsCustomOutputFolder(
          '/downloads/../downloads',
          '/downloads',
        ),
        isFalse,
      );
    });

    test('override for a genuinely different folder', () {
      expect(
        RqbitEngine.wantsCustomOutputFolder('/movies', '/downloads'),
        isTrue,
      );
    });
  });

  group('capabilities', () {
    late RqbitEngine engine;
    setUp(() => engine = RqbitEngine(port: 1));
    tearDown(() => engine.dispose());

    test('declares what it lacks so the UI can ask before rendering', () {
      final caps = engine.capabilities;
      expect(caps.trackers, isFalse, reason: 'no tracker table in the API');
      expect(caps.deltaSync, isFalse);
      expect(caps.rankedFilePriorities, isFalse, reason: 'include/exclude');
      expect(caps.seedsAndPeersSplit, isFalse);
      expect(caps.peerDetails, isFalse);
      expect(caps.liveSpeedLimits, isFalse, reason: 'they are launch flags');
      expect(caps.pieceLevelControl, isFalse);
      expect(caps.maintenanceActions, isFalse);
      expect(caps.peers, isTrue);
    });

    test('answers streamUrl — the whole reason this engine exists', () {
      expect(
        engine.streamUrl('ABCDEF', 3),
        'http://127.0.0.1:1/torrents/abcdef/stream/3',
      );
    });

    test(
      'ensureInOrderDownload succeeds without touching the engine',
      () async {
        // Inherited from TorrentEngine. A false here reads to StreamingService
        // as a dead session, and this engine is precisely one that needs no
        // sequential toggle.
        expect(await engine.ensureInOrderDownload('abc'), isTrue);
      },
    );
  });
}
