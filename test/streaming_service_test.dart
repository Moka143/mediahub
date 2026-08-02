import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_torrent_client/models/torrentio_stream.dart';
import 'package:flutter_torrent_client/services/streaming_service.dart';

StreamingSession _session({DateTime? createdAt}) => StreamingSession(
  id: 'session-1',
  stream: TorrentioStream(
    name: 'Test.Release.1080p',
    title: 'Test.Release.1080p',
    infoHash: 'abc123',
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
      expect(updated.stream.infoHash, 'abc123');
      expect(updated.state, StreamingState.buffering);
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
