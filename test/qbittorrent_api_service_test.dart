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
  });
}
