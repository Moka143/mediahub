import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/models/stream_request.dart';
import 'package:mediahub/models/torrentio_stream.dart';
import 'package:mediahub/services/streaming_service.dart';

StreamingSession _session({DateTime? createdAt}) => StreamingSession(
  id: 'session-1',
  request: StreamRequest.fromTorrentio(
    TorrentioStream(
      name: 'Test.Release.1080p',
      title: 'Test.Release.1080p',
      infoHash: 'abc123',
    ),
  ),
  createdAt: createdAt,
);

void main() {
  group('StreamingSession.copyWith', () {
    test('preserves createdAt so session-age timeouts can fire', () {
      final created = DateTime(2026, 1, 1, 12);

      final updated = _session(
        createdAt: created,
      ).copyWith(bufferProgress: 0.5);

      expect(updated.createdAt, created);
    });

    test('preserves allowSlowBuffer across heartbeat copies', () {
      final session = StreamingSession(
        id: 'session-1',
        request: StreamRequest.fromTorrentio(
          TorrentioStream(
            name: 'Test.Release.1080p',
            title: 'Test.Release.1080p',
            infoHash: 'abc123',
          ),
        ),
        allowSlowBuffer: true,
      ).copyWith(bufferProgress: 0.2);

      expect(session.allowSlowBuffer, isTrue);
    });

    test('preserves createdAt across repeated heartbeat updates', () {
      // _updateSession copies the session on every 2 s poll tick. Age has to
      // keep accumulating across those copies — if it reset, metadataTimeout
      // and bufferTimeout would never be reachable.
      final created = DateTime(2026, 1, 1, 12);
      var session = _session(createdAt: created);

      for (var tick = 0; tick < 10; tick++) {
        session = session.copyWith(bufferProgress: tick / 10);
      }

      expect(session.createdAt, created);
    });

    test('defaults createdAt to now when not supplied', () {
      final before = DateTime.now();
      final session = _session();
      final after = DateTime.now();

      expect(session.createdAt.isBefore(before), isFalse);
      expect(session.createdAt.isAfter(after), isFalse);
    });

    test('carries unmodified fields through', () {
      final updated = _session(
        createdAt: DateTime(2026, 1, 1),
      ).copyWith(state: StreamingState.buffering);

      expect(updated.id, 'session-1');
      expect(updated.request.infoHash, 'abc123');
      expect(updated.state, StreamingState.buffering);
    });
  });

  group('assessBuffering', () {
    const mb = 1024 * 1024;
    const need = 80 * mb;

    BufferOutcome assess({
      int buffered = 0,
      int minBytes = need,
      double rate = 500 * 1024, // 500 KB/s — comfortably viable
      Duration sinceProgress = const Duration(seconds: 2),
      // Past rateWarmup — these cases exercise the rate projection, not the
      // warmup gate, which has its own test below.
      Duration sinceStart = const Duration(minutes: 2),
    }) => StreamingService.assessBuffering(
      bufferedBytes: buffered,
      minBytes: minBytes,
      bytesPerSecond: rate,
      sinceLastProgress: sinceProgress,
      sinceStart: sinceStart,
    );

    test('ready once the threshold is met', () {
      expect(assess(buffered: need), BufferOutcome.ready);
      expect(assess(buffered: need + 1), BufferOutcome.ready);
    });

    test('keeps waiting while progressing at a workable rate', () {
      expect(assess(buffered: 20 * mb), BufferOutcome.waiting);
    });

    test('200 KB/s is slow but viable and must NOT be abandoned', () {
      // The regression this whole assessment exists for. The old flat
      // 5-minute deadline made 80 MB unreachable below ~273 KB/s, so a
      // perfectly streamable torrent failed after spinning for five minutes.
      // 80 MB at 200 KB/s is ~6.8 min — longer than the old deadline, well
      // inside what we should tolerate.
      expect(assess(buffered: 0, rate: 200 * 1024), BufferOutcome.waiting);
    });

    test('gives up on a rate that cannot get there in reasonable time', () {
      // 80 MB at 50 KB/s is ~27 min.
      expect(assess(buffered: 0, rate: 50 * 1024), BufferOutcome.tooSlow);
    });

    test('judges the projection on bytes REMAINING, not total', () {
      // Same slow rate, but nearly there — 1 MB at 50 KB/s is 20 s.
      expect(
        assess(buffered: need - mb, rate: 50 * 1024),
        BufferOutcome.waiting,
      );
    });

    test('ignores the rate estimate during warmup', () {
      // The opening seconds are handshakes, and a torrent routinely sits near
      // zero while it finds peers before climbing to megabytes a second. A
      // low reading in that window means nothing, and giving up on it was
      // the "provider slow" report.
      expect(
        assess(rate: 1024, sinceStart: const Duration(seconds: 5)),
        BufferOutcome.waiting,
      );
      expect(
        assess(rate: 1024, sinceStart: const Duration(seconds: 60)),
        BufferOutcome.waiting,
      );
      expect(
        assess(rate: 1024, sinceStart: StreamingService.rateWarmup),
        BufferOutcome.tooSlow,
      );
    });

    test('a slow start is judged against the prefix, not a 10% floor', () {
      // The regression this pair pins. Readiness is gated on a contiguous
      // prefix (8 MB), but the projection used to run against
      // minBufferBytesFor() — 80 MB or 10% of the file. At 133 KB/s that
      // reads as 10 minutes and gives up, while the bytes actually needed
      // were a minute away.
      const prefix = 8 * mb;
      const slowStart = 133 * 1024.0;

      expect(
        assess(buffered: 0, minBytes: prefix, rate: slowStart),
        BufferOutcome.waiting,
      );
      // Same rate, judged against the old floor: abandoned.
      expect(
        assess(buffered: 0, minBytes: 80 * mb, rate: slowStart),
        BufferOutcome.tooSlow,
      );
    });

    test('reports a stall separately from slowness', () {
      // No bytes at all is a peer problem, and deserves a different message
      // from "too slow" — the user's remedy differs.
      expect(
        assess(buffered: 5 * mb, sinceProgress: const Duration(seconds: 120)),
        BufferOutcome.stalled,
      );
    });

    test('a stall is not reported before the window elapses', () {
      expect(
        assess(buffered: 5 * mb, sinceProgress: const Duration(seconds: 60)),
        BufferOutcome.waiting,
      );
    });

    test('readiness wins over stalled and too-slow', () {
      expect(
        assess(
          buffered: need,
          rate: 0,
          sinceProgress: const Duration(minutes: 10),
          sinceStart: const Duration(minutes: 30),
        ),
        BufferOutcome.ready,
      );
    });

    test('the hard ceiling ends even a progressing session', () {
      // gaveUp, not tooSlow: a background prefetch (`allowSlowBuffer`) is
      // allowed to swallow tooSlow/stalled indefinitely, so the deadline
      // needs its own outcome or such a session never stops polling.
      expect(
        assess(buffered: 10 * mb, sinceStart: const Duration(minutes: 25)),
        BufferOutcome.gaveUp,
      );
    });

    test('the hard ceiling outranks a healthy rate and fresh progress', () {
      expect(
        assess(
          buffered: 10 * mb,
          rate: 5 * mb.toDouble(),
          sinceProgress: Duration.zero,
          sinceStart: StreamingService.bufferHardCeiling,
        ),
        BufferOutcome.gaveUp,
      );
    });

    test('a zero rate before the stall window just keeps waiting', () {
      // Rate unknown yet — not enough to condemn it.
      expect(
        assess(rate: 0, sinceProgress: const Duration(seconds: 10)),
        BufferOutcome.waiting,
      );
    });
  });

  group('chooseStreamSource', () {
    // The decision the whole engine swap turns on. Three ways to reach the
    // bytes, and the wrong one is not an error — it is a player that spins
    // forever or a video full of garbage.
    test('a finished file is opened from disk, engine URL or not', () {
      // Checked before the engine is asked, deliberately: handing mpv a
      // multi-gigabyte HTTP body makes it try, and fail, to build a demuxer
      // file cache. That was the "download finished but it still didn't
      // play" case, and it applies to any HTTP source.
      expect(
        StreamingService.chooseStreamSource(
          fileComplete: true,
          engineUrl: 'http://127.0.0.1:3030/torrents/abc/stream/0',
        ),
        StreamSource.disk,
      );
      expect(
        StreamingService.chooseStreamSource(
          fileComplete: true,
          engineUrl: null,
        ),
        StreamSource.disk,
      );
    });

    test('an engine that serves its own files needs no proxy', () {
      expect(
        StreamingService.chooseStreamSource(
          fileComplete: false,
          engineUrl: 'http://127.0.0.1:3030/torrents/abc/stream/0',
        ),
        StreamSource.engine,
      );
    });

    test('a downloader backend still gets the proxy', () {
      // qBittorrent pre-allocates and its gaps read back as zeros, which the
      // demuxer decodes as corrupt video. Something has to stand in front.
      expect(
        StreamingService.chooseStreamSource(
          fileComplete: false,
          engineUrl: null,
        ),
        StreamSource.proxy,
      );
    });
  });
}
