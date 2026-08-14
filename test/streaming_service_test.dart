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
      Duration sinceStart = const Duration(minutes: 1),
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
      // The first seconds are handshakes; a low reading there means nothing.
      expect(
        assess(rate: 1024, sinceStart: const Duration(seconds: 5)),
        BufferOutcome.waiting,
      );
      expect(
        assess(rate: 1024, sinceStart: const Duration(seconds: 45)),
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
      expect(
        assess(buffered: 10 * mb, sinceStart: const Duration(minutes: 25)),
        BufferOutcome.tooSlow,
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

  group('StreamingService.minBufferBytesFor', () {
    const absoluteMin = 80 * 1024 * 1024;
    const absoluteCap = 500 * 1024 * 1024;

    test('returns the absolute minimum for a zero or negative size', () {
      expect(StreamingService.minBufferBytesFor(0), absoluteMin);
      expect(StreamingService.minBufferBytesFor(-1), absoluteMin);
    });

    test('floors small files at the absolute minimum', () {
      expect(
        StreamingService.minBufferBytesFor(100 * 1024 * 1024),
        absoluteMin,
      );
    });

    test('800 MB sits exactly on the floor', () {
      expect(
        StreamingService.minBufferBytesFor(800 * 1024 * 1024),
        absoluteMin,
      );
    });

    test('uses 10 percent between the floor and the cap', () {
      expect(
        StreamingService.minBufferBytesFor(2 * 1024 * 1024 * 1024),
        214748365,
      );
    });

    test('caps large files at the absolute maximum', () {
      expect(
        StreamingService.minBufferBytesFor(5 * 1024 * 1024 * 1024),
        absoluteCap,
      );
      expect(
        StreamingService.minBufferBytesFor(50 * 1024 * 1024 * 1024),
        absoluteCap,
      );
    });
  });
}
