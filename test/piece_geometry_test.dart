import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/services/piece_geometry.dart';

const mib = 1024 * 1024;

/// A piece map with [done] pieces complete and everything else missing.
List<int> statesWith(int total, Set<int> done) => [
  for (var i = 0; i < total; i++) done.contains(i) ? 2 : 0,
];

void main() {
  group('a file that starts on a piece boundary', () {
    // 10 pieces of 1 MiB covering a 10 MiB file starting at piece 100 — the
    // only shape the old maths handled, and it must keep handling it.
    const pieceSize = mib;
    const fileSize = 10 * pieceSize;
    const map = FilePieceMap(
      pieceSize: pieceSize,
      fileOffset: 100 * pieceSize,
      fileSize: fileSize,
    );

    List<int> states(List<int> fileStates) => [
      ...List<int>.filled(100, 0),
      ...fileStates,
    ];

    test('covers exactly its own pieces', () {
      expect(map.firstPiece, 100);
      expect(map.lastPiece, 109);
    });

    test('a fully downloaded file is one run covering every byte', () {
      expect(map.availableRanges(states(List<int>.filled(10, 2))), [
        const ByteRange(0, fileSize - 1),
      ]);
    });

    test('an empty file has no runs', () {
      expect(map.availableRanges(states(List<int>.filled(10, 0))), isEmpty);
    });

    test('scattered pieces produce separate runs', () {
      expect(map.availableRanges(states([2, 2, 0, 0, 2, 2, 0, 0, 2, 2])), [
        const ByteRange(0, 2 * pieceSize - 1),
        const ByteRange(4 * pieceSize, 6 * pieceSize - 1),
        const ByteRange(8 * pieceSize, fileSize - 1),
      ]);
    });

    test('a downloading piece (state 1) is not available', () {
      expect(map.availableRanges(states([2, 1, 2, 0, 0, 0, 0, 0, 0, 0])), [
        const ByteRange(0, pieceSize - 1),
        const ByteRange(2 * pieceSize, 3 * pieceSize - 1),
      ]);
    });

    test('a truncated piece map reads as missing past its end', () {
      expect(map.availableRanges([...List<int>.filled(100, 0), 2, 2]), [
        const ByteRange(0, 2 * pieceSize - 1),
      ]);
      expect(
        map.firstUnavailableFrom(0, [...List<int>.filled(100, 0), 2, 2]),
        2 * pieceSize,
      );
    });

    test('firstUnavailableFrom walks to the first missing piece', () {
      final s = states([2, 2, 2, 0, 2, 2, 2, 2, 2, 2]);
      expect(map.firstUnavailableFrom(0, s), 3 * pieceSize);
      expect(map.firstUnavailableFrom(pieceSize + 5, s), 3 * pieceSize);
      expect(map.firstUnavailableFrom(3 * pieceSize, s), 3 * pieceSize);
      expect(map.firstUnavailableFrom(4 * pieceSize, s), fileSize);
      expect(map.firstUnavailableFrom(fileSize, s), fileSize);
    });

    test('one complete leading piece is a ready head', () {
      // The regression the head check was shaped by: sequential had finished
      // the first piece while the second never completed, and a longer run
      // requirement sat there until 99%.
      expect(
        map.headReady(states([2, 0, 0, 0, 0, 0, 0, 0, 0, 0]), bytes: pieceSize),
        isTrue,
      );
      expect(
        map.headReady(states([1, 2, 2, 2, 2, 2, 2, 2, 2, 2]), bytes: pieceSize),
        isFalse,
      );
    });

    test('the final run stops at the end of a short last piece', () {
      const short = FilePieceMap(
        pieceSize: pieceSize,
        fileOffset: 100 * pieceSize,
        fileSize: fileSize - mib ~/ 2,
      );
      expect(short.availableRanges(states(List<int>.filled(10, 2))), [
        const ByteRange(0, fileSize - mib ~/ 2 - 1),
      ]);
    });
  });

  group('a season-pack episode that starts mid-piece', () {
    // The audit's example: 4 MiB pieces, E02 starts at torrent offset
    // 351 MiB, so its first piece is 87 (348–352 MiB) and only the last
    // 1 MiB of that piece belongs to it.
    const pieceSize = 4 * mib;
    const map = FilePieceMap(
      pieceSize: pieceSize,
      fileOffset: 351 * mib,
      fileSize: 300 * mib,
    );

    test('starts in piece 87 and spans 76 pieces', () {
      expect(map.firstPiece, 87);
      expect(map.lastPiece, (351 * mib + 300 * mib - 1) ~/ pieceSize);
    });

    test('with piece 87 done and 88 missing, only 1 MiB is available', () {
      // The old maths said 4 MiB — and served three of sparse zeros.
      final s = statesWith(200, {87});
      expect(map.firstUnavailableFrom(0, s), 1 * mib);
      expect(map.availableRanges(s), [const ByteRange(0, mib - 1)]);
    });

    test('a byte in piece 88 is missing even though piece 87 is done', () {
      final s = statesWith(200, {87});
      expect(map.firstUnavailableFrom(mib, s), mib);
      expect(map.firstUnavailableFrom(mib + 100, s), mib + 100);
    });

    test('piece boundaries land at fileOffset-relative positions', () {
      // Pieces 87–90 done, 91 missing: the run ends where piece 91 begins,
      // 91·4 MiB − 351 MiB = 13 MiB into the file.
      final s = statesWith(200, {87, 88, 89, 90});
      expect(map.firstUnavailableFrom(0, s), 13 * mib);
      expect(map.availableRanges(s), [const ByteRange(0, 13 * mib - 1)]);
    });

    test('the head needs more than piece 87 to hold a piece of data', () {
      expect(
        map.headReady(statesWith(200, {87}), bytes: pieceSize),
        isFalse,
        reason: 'piece 87 holds only 1 MiB of this file',
      );
      expect(
        map.headReady(statesWith(200, {87, 88}), bytes: pieceSize),
        isTrue,
      );
    });

    test('a later run is placed by the file offset too', () {
      // Pieces 100–101 done: torrent bytes 400–408 MiB, file bytes 49–57 MiB.
      final s = statesWith(200, {100, 101});
      expect(map.availableRanges(s), [const ByteRange(49 * mib, 57 * mib - 1)]);
    });
  });

  group('an offset known only to within a range', () {
    // A 10 MiB file whose engine-reported range is pieces 5–8 of 4 MiB: any
    // offset from just past 22 MiB to just under 24 MiB would fit, so every
    // byte must have all its candidate pieces complete.
    const pieceSize = 4 * mib;
    final map = PieceGeometry.forSizes(
      fileSizes: const [0, 10 * mib],
      fileIndex: 1,
      pieceSize: pieceSize,
      listedRange: const [5, 8],
    )!;

    test('keeps the reported range', () {
      expect(map.firstPiece, 5);
      expect(map.lastPiece, 8);
      expect(map.offsetUncertainty, greaterThan(0));
    });

    test('a byte that may sit in a missing piece is not available', () {
      // Piece 5 done, 6 missing: the first byte that might be in piece 6
      // under the latest consistent offset is the edge.
      final s = statesWith(20, {5});
      final edge = map.firstUnavailableFrom(0, s);
      final latestOffset = map.fileOffset + map.offsetUncertainty;
      expect(edge, 6 * pieceSize - latestOffset);
      // And never more than the exact answer for the earliest offset.
      expect(edge, lessThanOrEqualTo(6 * pieceSize - map.fileOffset));
    });

    test('every piece done means every byte is there', () {
      final s = statesWith(20, {5, 6, 7, 8});
      expect(map.firstUnavailableFrom(0, s), 10 * mib);
      expect(map.availableRanges(s), [const ByteRange(0, 10 * mib - 1)]);
    });
  });

  group('PieceGeometry.forFile', () {
    TorrentFile file(int index, int size, {List<int>? range}) => TorrentFile(
      index: index,
      name: 'Show/E0$index.mkv',
      size: size,
      progress: 0,
      priority: 1,
      isSeed: false,
      pieceRange: range,
      availability: 0,
    );

    test('sums the sizes of the files before it', () {
      final map = PieceGeometry.forFile(
        files: [file(0, 351 * mib), file(1, 300 * mib), file(2, 10 * mib)],
        fileIndex: 1,
        pieceSize: 4 * mib,
      );
      expect(map?.fileOffset, 351 * mib);
      expect(map?.offsetUncertainty, 0);
    });

    test('trusts the summed offset when it agrees with piece_range', () {
      final map = PieceGeometry.forFile(
        files: [
          file(0, 351 * mib, range: [0, 87]),
          file(1, 300 * mib, range: [87, 162]),
        ],
        fileIndex: 1,
        pieceSize: 4 * mib,
      );
      expect(map?.fileOffset, 351 * mib);
      expect(map?.offsetUncertainty, 0);
    });

    test('falls back to the reported range when padding is hidden', () {
      // qBittorrent hides BEP 47 padding: the summed offset (351 MiB, piece
      // 87) disagrees with the file's real start at piece 88.
      final map = PieceGeometry.forFile(
        files: [
          file(0, 351 * mib, range: [0, 87]),
          file(1, 300 * mib, range: [88, 162]),
        ],
        fileIndex: 1,
        pieceSize: 4 * mib,
      );
      expect(map, isNotNull);
      expect(map!.firstPiece, 88);
      expect(map.lastPiece, 162);
    });

    test('answers null rather than guessing', () {
      expect(
        PieceGeometry.forFile(
          files: [file(0, mib)],
          fileIndex: 0,
          pieceSize: 0,
        ),
        isNull,
      );
      expect(
        PieceGeometry.forFile(
          files: [file(0, mib)],
          fileIndex: 3,
          pieceSize: mib,
        ),
        isNull,
      );
      expect(
        PieceGeometry.forFile(
          files: [file(0, 0)],
          fileIndex: 0,
          pieceSize: mib,
        ),
        isNull,
      );
    });
  });
}
