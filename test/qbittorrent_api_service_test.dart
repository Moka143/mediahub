import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_torrent_client/services/qbittorrent_api_service.dart';

void main() {
  group('streaming piece readiness', () {
    test('checks the selected file range instead of torrent piece zero', () {
      final pieceStates = [2, 2, 2, 2, 0, 2, 2, 2];

      final ready = QBittorrentApiService.isPieceRangeReadyForStreaming(
        pieceStates: pieceStates,
        pieceRange: [4, 7],
        fileSizeBytes: 400,
        minProgress: 0.5,
      );

      expect(ready, isFalse);
    });

    test('uses the byte buffer budget when it is larger than percentage', () {
      final pieceStates = [...List.filled(24, 2), ...List.filled(76, 0)];

      final ready = QBittorrentApiService.isPieceRangeReadyForStreaming(
        pieceStates: pieceStates,
        pieceRange: [0, 99],
        fileSizeBytes: 1000,
        minProgress: 0.03,
        minBufferBytes: 250,
      );

      expect(ready, isFalse);
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: 100,
          fileSizeBytes: 1000,
          minProgress: 0.03,
          minBufferBytes: 250,
        ),
        25,
      );
    });

    test('passes when enough selected-file pieces are contiguous', () {
      final pieceStates = [...List.filled(25, 2), ...List.filled(75, 0)];

      final ready = QBittorrentApiService.isPieceRangeReadyForStreaming(
        pieceStates: pieceStates,
        pieceRange: [0, 99],
        fileSizeBytes: 1000,
        minProgress: 0.03,
        minBufferBytes: 250,
      );

      expect(ready, isTrue);
    });

    test('empty piece states are never ready', () {
      expect(
        QBittorrentApiService.isPieceRangeReadyForStreaming(
          pieceStates: const [],
          pieceRange: [0, 9],
          fileSizeBytes: 1000,
          minProgress: 0.5,
        ),
        isFalse,
      );
    });

    test('a piece range with fewer than two entries is never ready', () {
      expect(
        QBittorrentApiService.isPieceRangeReadyForStreaming(
          pieceStates: List.filled(8, 2),
          pieceRange: [0],
          fileSizeBytes: 1000,
          minProgress: 0.5,
        ),
        isFalse,
      );
    });

    test('an out-of-range piece range is clamped, not an index error', () {
      // Regression guard: the readiness loop bounds itself on the clamped
      // range. A range past the end of pieceStates must clamp rather than
      // walk off the list.
      expect(
        QBittorrentApiService.isPieceRangeReadyForStreaming(
          pieceStates: List.filled(8, 2),
          pieceRange: [0, 999],
          fileSizeBytes: 1000,
          minProgress: 0.5,
        ),
        isTrue,
      );
    });

    test('an inverted piece range is never ready', () {
      expect(
        QBittorrentApiService.isPieceRangeReadyForStreaming(
          pieceStates: List.filled(8, 2),
          pieceRange: [5, 2],
          fileSizeBytes: 1000,
          minProgress: 0.5,
        ),
        isFalse,
      );
    });
  });

  group('requiredContiguousPiecesForStreaming', () {
    test('returns zero for an empty file piece count', () {
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: 0,
          fileSizeBytes: 1000,
          minProgress: 0.5,
        ),
        0,
      );
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: -5,
          fileSizeBytes: 1000,
          minProgress: 0.5,
        ),
        0,
      );
    });

    test('always requires at least one piece', () {
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: 100,
          fileSizeBytes: 1000,
          minProgress: 0.0,
        ),
        1,
      );
    });

    test('clamps minProgress above one', () {
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: 100,
          fileSizeBytes: 1000,
          minProgress: 2.0,
        ),
        100,
      );
    });

    test('clamps a negative minProgress to the one-piece floor', () {
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: 100,
          fileSizeBytes: 1000,
          minProgress: -1.0,
        ),
        1,
      );
    });

    test('never exceeds the file piece count', () {
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: 100,
          fileSizeBytes: 1000,
          minProgress: 0.1,
          minBufferBytes: 5000,
        ),
        100,
      );
    });

    test('ignores the byte budget when the file size is unknown', () {
      expect(
        QBittorrentApiService.requiredContiguousPiecesForStreaming(
          filePieceCount: 100,
          fileSizeBytes: 0,
          minProgress: 0.25,
          minBufferBytes: 500,
        ),
        25,
      );
    });
  });

  group('isSuccessStatus', () {
    test('accepts the whole 2xx range', () {
      expect(QBittorrentApiService.isSuccessStatus(200), isTrue);
      // qBittorrent 5.2.0 returns 204 for empty-body successes.
      expect(QBittorrentApiService.isSuccessStatus(204), isTrue);
      expect(QBittorrentApiService.isSuccessStatus(299), isTrue);
    });

    test('rejects everything outside 2xx', () {
      expect(QBittorrentApiService.isSuccessStatus(199), isFalse);
      expect(QBittorrentApiService.isSuccessStatus(300), isFalse);
      expect(QBittorrentApiService.isSuccessStatus(403), isFalse);
      expect(QBittorrentApiService.isSuccessStatus(500), isFalse);
    });

    test('rejects a null status', () {
      expect(QBittorrentApiService.isSuccessStatus(null), isFalse);
    });
  });
}
