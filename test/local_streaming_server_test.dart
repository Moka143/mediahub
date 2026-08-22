import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/services/local_streaming_server.dart';

/// Matches the private `_tailProbeWindow` on the server (8 MB).
const _tailProbeWindow = 8 * 1024 * 1024;

/// Matches the private `_minTailProbeFileSize` (4x the window).
const _minTailProbeFileSize = 4 * _tailProbeWindow;

void main() {
  group('parseRangeHeader — no usable range', () {
    test('an absent header serves the whole file as a 200', () {
      final range = LocalStreamingServer.parseRangeHeader(null, 1000);

      expect(range.satisfiable, isTrue);
      expect(range.partial, isFalse);
      expect(range.start, 0);
      expect(range.end, 999);
    });

    test('a non-bytes unit is ignored rather than rejected', () {
      final range = LocalStreamingServer.parseRangeHeader('items=0-99', 1000);

      expect(range.partial, isFalse);
      expect(range.start, 0);
      expect(range.end, 999);
    });

    test('a bytes value with no dash serves the whole file', () {
      // Deliberate leniency: this is a 200, not a 416.
      final range = LocalStreamingServer.parseRangeHeader('bytes=abc', 1000);

      expect(range.satisfiable, isTrue);
      expect(range.partial, isFalse);
      expect(range.end, 999);
    });

    test('an empty bytes value serves the whole file', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=', 1000);

      expect(range.partial, isFalse);
      expect(range.end, 999);
    });
  });

  group('parseRangeHeader — explicit ranges', () {
    test('parses a closed range', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=0-99', 1000);

      expect(range.satisfiable, isTrue);
      expect(range.partial, isTrue);
      expect(range.start, 0);
      expect(range.end, 99);
    });

    test('an open-ended range runs to EOF', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=500-', 1000);

      expect(range.start, 500);
      expect(range.end, 999);
      expect(range.partial, isTrue);
    });

    test('an over-long end is clamped rather than rejected', () {
      final range = LocalStreamingServer.parseRangeHeader(
        'bytes=0-999999',
        1000,
      );

      expect(range.satisfiable, isTrue);
      expect(range.end, 999);
    });

    test('an unparseable start falls back to zero', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=abc-99', 1000);

      expect(range.start, 0);
      expect(range.end, 99);
    });

    test('an unparseable end falls back to EOF', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=50-xyz', 1000);

      expect(range.start, 50);
      expect(range.end, 999);
    });

    test('only the first range of a comma-separated list is honoured', () {
      // Single-range reply; the remaining ranges are silently dropped rather
      // than answered as multipart/byteranges.
      final range = LocalStreamingServer.parseRangeHeader(
        'bytes=0-99,200-299',
        1000,
      );

      expect(range.start, 0);
      expect(range.end, 99);
    });
  });

  group('parseRangeHeader — suffix ranges', () {
    test('serves the last N bytes', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=-500', 1000);

      expect(range.start, 500);
      expect(range.end, 999);
      expect(range.partial, isTrue);
    });

    test('a suffix longer than the file serves the whole file', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=-5000', 1000);

      expect(range.start, 0);
      expect(range.end, 999);
    });

    test('a zero-length suffix serves the final byte', () {
      // RFC 7233 says 416 here; this parser deliberately does not, and mpv
      // relies on the lenient behaviour.
      final range = LocalStreamingServer.parseRangeHeader('bytes=-0', 1000);

      expect(range.satisfiable, isTrue);
      expect(range.start, 999);
      expect(range.end, 999);
    });

    test('an unparseable suffix length serves the final byte', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=-xyz', 1000);

      expect(range.start, 999);
      expect(range.end, 999);
    });

    test('a bare dash is treated as the whole file, not a suffix', () {
      // Both sides empty falls through to the explicit-range branch.
      final range = LocalStreamingServer.parseRangeHeader('bytes=-', 1000);

      expect(range.start, 0);
      expect(range.end, 999);
      expect(range.partial, isTrue);
    });
  });

  group('parseRangeHeader — unsatisfiable', () {
    test('an inverted range is unsatisfiable', () {
      final range = LocalStreamingServer.parseRangeHeader(
        'bytes=500-100',
        1000,
      );

      expect(range.satisfiable, isFalse);
    });

    test('a start at or past EOF is unsatisfiable', () {
      expect(
        LocalStreamingServer.parseRangeHeader('bytes=1000-', 1000).satisfiable,
        isFalse,
      );
      expect(
        LocalStreamingServer.parseRangeHeader('bytes=5000-', 1000).satisfiable,
        isFalse,
      );
    });

    test('the final byte of the file is still satisfiable', () {
      final range = LocalStreamingServer.parseRangeHeader('bytes=999-', 1000);

      expect(range.satisfiable, isTrue);
      expect(range.start, 999);
      expect(range.end, 999);
    });
  });

  group('parseRangeHeader — openEnded flag', () {
    // Drives clampOpenEndedEnd: only a range the client left open may be
    // shortened, because its end is our default rather than their ask.
    test('bytes=N- is open-ended', () {
      expect(
        LocalStreamingServer.parseRangeHeader('bytes=0-', 1000).openEnded,
        isTrue,
      );
      expect(
        LocalStreamingServer.parseRangeHeader('bytes=500-', 1000).openEnded,
        isTrue,
      );
    });

    test('a closed range is not open-ended', () {
      expect(
        LocalStreamingServer.parseRangeHeader('bytes=0-999', 1000).openEnded,
        isFalse,
      );
    });

    test('a suffix range is not open-ended', () {
      expect(
        LocalStreamingServer.parseRangeHeader('bytes=-200', 1000).openEnded,
        isFalse,
      );
    });

    test('an absent header is not open-ended', () {
      expect(
        LocalStreamingServer.parseRangeHeader(null, 1000).openEnded,
        isFalse,
      );
    });
  });

  group('clampOpenEndedEnd', () {
    const min = LocalStreamingServer.minClampedChunk;
    const fileEnd = 400 * 1024 * 1024;

    int clamp({
      int start = 0,
      int requestedEnd = fileEnd,
      required int firstUnavailableByte,
      bool openEnded = true,
    }) => LocalStreamingServer.clampOpenEndedEnd(
      start: start,
      requestedEnd: requestedEnd,
      firstUnavailableByte: firstUnavailableByte,
      openEnded: openEnded,
    );

    test('shortens an open-ended range to the available run', () {
      // The real failure: mpv asked for all 400 MB while 92 MB was on disk,
      // so the response promised 400 MB and then stalled mid-body.
      const available = 92 * 1024 * 1024;
      expect(clamp(firstUnavailableByte: available), available - 1);
    });

    test('leaves a bounded request exactly as asked', () {
      expect(
        clamp(requestedEnd: 1023, firstUnavailableByte: 4096, openEnded: false),
        1023,
      );
    });

    test('does not shorten when everything requested is already on disk', () {
      expect(clamp(firstUnavailableByte: fileEnd + 1), fileEnd);
    });

    test('does not shorten a run below the minimum chunk', () {
      // Would otherwise turn one stalled request into a storm of tiny ones.
      expect(clamp(firstUnavailableByte: min - 1), fileEnd);
    });

    test('shortens at exactly the minimum chunk', () {
      expect(clamp(firstUnavailableByte: min), min - 1);
    });

    test('a seek past the download edge still blocks rather than clamping', () {
      // start itself is unavailable, so firstUnavailable == start. Clamping
      // here would return an empty body; the blocking path plus the
      // seek-past-head indicator is the intended behaviour.
      const start = 300 * 1024 * 1024;
      expect(
        clamp(start: start, firstUnavailableByte: start),
        fileEnd,
        reason: 'must fall through to the blocking read',
      );
    });

    test('measures the run from start, not from zero', () {
      // 2 MB available beyond a mid-file start is below the floor even though
      // the absolute offset is large.
      const start = 100 * 1024 * 1024;
      expect(
        clamp(start: start, firstUnavailableByte: start + 2 * 1024 * 1024),
        fileEnd,
      );
    });

    test('minRun: 1 serves a short run rather than over-promising', () {
      // What the request handler does after it has already waited for the
      // run to grow. Returning `fileEnd` here would advertise a
      // Content-Length of the whole remaining file and then stall mid-body —
      // libav abandons the open instead of asking again, so a seek into a
      // thinly-buffered region never completes.
      const start = 100 * 1024 * 1024;
      const available = start + 2 * 1024 * 1024;

      expect(
        LocalStreamingServer.clampOpenEndedEnd(
          start: start,
          requestedEnd: fileEnd,
          firstUnavailableByte: available,
          openEnded: true,
          minRun: 1,
        ),
        available - 1,
      );
    });

    test('minRun: 1 still blocks when nothing at all is available', () {
      // A genuine seek past the download edge: there is no run to serve, so
      // the blocking path plus the seek-past-head indicator must still win.
      const start = 300 * 1024 * 1024;

      expect(
        LocalStreamingServer.clampOpenEndedEnd(
          start: start,
          requestedEnd: fileEnd,
          firstUnavailableByte: start,
          openEnded: true,
          minRun: 1,
        ),
        fileEnd,
      );
    });
  });

  group('availableRanges', () {
    // 10 pieces of 1 MB covering a 10 MB file starting at piece 100.
    const pieceSize = 1024 * 1024;
    const firstPiece = 100;
    const lastPiece = 109;
    const fileSize = 10 * pieceSize;

    List<ByteRange> ranges(List<int> fileStates) {
      // Pad the leading pieces that belong to earlier files in the torrent.
      final states = [...List<int>.filled(firstPiece, 0), ...fileStates];
      return LocalStreamingServer.availableRanges(
        pieceStates: states,
        firstPiece: firstPiece,
        lastPiece: lastPiece,
        pieceSize: pieceSize,
        fileSize: fileSize,
      );
    }

    test('a fully downloaded file is one run covering every byte', () {
      expect(ranges(List<int>.filled(10, 2)), [
        const ByteRange(0, fileSize - 1),
      ]);
    });

    test('an empty file has no runs', () {
      expect(ranges(List<int>.filled(10, 0)), isEmpty);
    });

    test('a sequential prefix is a single run from zero', () {
      expect(ranges([2, 2, 2, 0, 0, 0, 0, 0, 0, 0]), [
        const ByteRange(0, 3 * pieceSize - 1),
      ]);
    });

    test('scattered pieces produce separate runs', () {
      // The case the scalar progress fraction cannot express: 50% downloaded,
      // but the first 50% of the file is *not* what is on disk.
      expect(ranges([2, 2, 0, 0, 2, 2, 0, 0, 2, 2]), [
        const ByteRange(0, 2 * pieceSize - 1),
        ByteRange(4 * pieceSize, 6 * pieceSize - 1),
        ByteRange(8 * pieceSize, fileSize - 1),
      ]);
    });

    test('a downloading piece (state 1) is not available', () {
      expect(ranges([2, 1, 2, 0, 0, 0, 0, 0, 0, 0]), [
        const ByteRange(0, pieceSize - 1),
        ByteRange(2 * pieceSize, 3 * pieceSize - 1),
      ]);
    });

    test('the final run is clamped to the file size', () {
      // The last piece of a file usually runs past its end into the next
      // file; the run must stop at the file boundary.
      const shortFile = fileSize - 512 * 1024;
      final result = LocalStreamingServer.availableRanges(
        pieceStates: [
          ...List<int>.filled(firstPiece, 0),
          ...List.filled(10, 2),
        ],
        firstPiece: firstPiece,
        lastPiece: lastPiece,
        pieceSize: pieceSize,
        fileSize: shortFile,
      );

      expect(result, [ByteRange(0, shortFile - 1)]);
    });

    test('a truncated piece-state array stops at what it has', () {
      // qBittorrent occasionally returns fewer entries than the piece range
      // implies; walking past the end would throw.
      final result = LocalStreamingServer.availableRanges(
        pieceStates: [...List<int>.filled(firstPiece, 0), 2, 2],
        firstPiece: firstPiece,
        lastPiece: lastPiece,
        pieceSize: pieceSize,
        fileSize: fileSize,
      );

      expect(result, [const ByteRange(0, 2 * pieceSize - 1)]);
    });

    test('unusable inputs yield no runs rather than a wrong answer', () {
      expect(ranges(const []), isEmpty);
      expect(
        LocalStreamingServer.availableRanges(
          pieceStates: List<int>.filled(110, 2),
          firstPiece: firstPiece,
          lastPiece: lastPiece,
          pieceSize: 0,
          fileSize: fileSize,
        ),
        isEmpty,
      );
      expect(
        LocalStreamingServer.availableRanges(
          pieceStates: List<int>.filled(110, 2),
          firstPiece: firstPiece,
          lastPiece: lastPiece,
          pieceSize: pieceSize,
          fileSize: 0,
        ),
        isEmpty,
      );
    });
  });

  group('isTailProbeStart', () {
    const hundredMb = 100 * 1024 * 1024;

    test('is inclusive at the window boundary', () {
      final threshold = hundredMb - _tailProbeWindow;

      expect(
        LocalStreamingServer.isTailProbeStart(threshold, hundredMb),
        isTrue,
      );
      expect(
        LocalStreamingServer.isTailProbeStart(threshold - 1, hundredMb),
        isFalse,
      );
    });

    test('the start of a large file is not a tail probe', () {
      expect(LocalStreamingServer.isTailProbeStart(0, hundredMb), isFalse);
    });

    test('a small file never counts as a tail probe', () {
      // The window is absolute, so without the size guard every offset of a
      // sub-window file would fast-fail with a 416 and the file could never
      // stream at all — it would only ever play once fully downloaded.
      const tenMb = 10 * 1024 * 1024;

      expect(LocalStreamingServer.isTailProbeStart(0, tenMb), isFalse);
      expect(LocalStreamingServer.isTailProbeStart(tenMb - 1, tenMb), isFalse);
    });

    test('the size guard is inclusive at its own boundary', () {
      const size = _minTailProbeFileSize;

      expect(
        LocalStreamingServer.isTailProbeStart(size - 1, size),
        isTrue,
        reason: 'at the threshold the rule applies',
      );
      expect(
        LocalStreamingServer.isTailProbeStart(size - 2, size - 1),
        isFalse,
        reason: 'one byte under, it does not',
      );
    });

    test('leaves the seekable body of a mid-size file alone', () {
      // The regression this window was shrunk for: at 64 MB, seeking to 90%
      // of a 500 MB episode landed inside the "probe" window and answered
      // 416, so the seek failed and playback fell back to the spinner.
      const fiveHundredMb = 500 * 1024 * 1024;
      final ninetyPercent = (fiveHundredMb * 0.9).round();

      expect(
        LocalStreamingServer.isTailProbeStart(ninetyPercent, fiveHundredMb),
        isFalse,
      );
    });
  });

  group('guessContentType', () {
    test('maps the container extensions mpv cares about', () {
      expect(
        LocalStreamingServer.guessContentType('Show.S01E01.mkv'),
        'video/x-matroska',
      );
      expect(LocalStreamingServer.guessContentType('a.mp4'), 'video/mp4');
      expect(LocalStreamingServer.guessContentType('a.m4v'), 'video/mp4');
      expect(LocalStreamingServer.guessContentType('a.webm'), 'video/webm');
      expect(LocalStreamingServer.guessContentType('a.mov'), 'video/quicktime');
      expect(LocalStreamingServer.guessContentType('a.avi'), 'video/x-msvideo');
      expect(LocalStreamingServer.guessContentType('a.ts'), 'video/mp2t');
      expect(LocalStreamingServer.guessContentType('a.m2ts'), 'video/mp2t');
      expect(LocalStreamingServer.guessContentType('a.mpg'), 'video/mpeg');
      expect(LocalStreamingServer.guessContentType('a.mpeg'), 'video/mpeg');
    });

    test('is case-insensitive', () {
      expect(
        LocalStreamingServer.guessContentType('MOVIE.MKV'),
        'video/x-matroska',
      );
    });

    test('uses only the final extension of a dotted release name', () {
      expect(
        LocalStreamingServer.guessContentType('Show.S01E01.1080p.WEB-DL.ts'),
        'video/mp2t',
      );
    });

    test('falls back to octet-stream for anything unrecognised', () {
      expect(
        LocalStreamingServer.guessContentType('noextension'),
        'application/octet-stream',
      );
      expect(
        LocalStreamingServer.guessContentType('archive.zip'),
        'application/octet-stream',
      );
    });
  });

  group('looksLikeContainerHeader', () {
    test('accepts Matroska EBML magic', () {
      expect(
        LocalStreamingServer.looksLikeContainerHeader([
          0x1A,
          0x45,
          0xDF,
          0xA3,
          0x01,
          0x00,
        ]),
        isTrue,
      );
    });

    test('rejects qBittorrent sparse zeros', () {
      expect(
        LocalStreamingServer.looksLikeContainerHeader([0, 0, 0, 0, 0, 0, 0, 0]),
        isFalse,
      );
    });

    test('accepts an MP4 ftyp box', () {
      expect(
        LocalStreamingServer.looksLikeContainerHeader([
          0x00,
          0x00,
          0x00,
          0x20,
          ...'ftyp'.codeUnits,
        ]),
        isTrue,
      );
    });
  });

  group('pieceRangeForFile', () {
    test('maps the middle file of a season pack onto its pieces', () {
      // 32 MB pieces, three files: 40 MB, 100 MB, 60 MB.
      const piece = 32 * 1024 * 1024;
      final sizes = [40 * 1024 * 1024, 100 * 1024 * 1024, 60 * 1024 * 1024];

      expect(
        LocalStreamingServer.pieceRangeForFile(
          fileSizes: sizes,
          fileIndex: 1,
          pieceSize: piece,
        ),
        (1, 4),
      );
    });

    test('returns null when piece size or index is unusable', () {
      expect(
        LocalStreamingServer.pieceRangeForFile(
          fileSizes: [100],
          fileIndex: 0,
          pieceSize: 0,
        ),
        isNull,
      );
      expect(
        LocalStreamingServer.pieceRangeForFile(
          fileSizes: [100],
          fileIndex: 3,
          pieceSize: 16,
        ),
        isNull,
      );
    });
  });

  group('prefixPiecesReady', () {
    const piece = 16 * 1024 * 1024; // 16 MB pieces

    test('is false until the leading pieces are fully downloaded', () {
      // File starts at piece 10. 36% of the file can be state-2 while
      // piece 10 is still empty — that must not look ready.
      final states = List<int>.filled(20, 0);
      for (var i = 12; i < 18; i++) {
        states[i] = 2;
      }

      expect(
        LocalStreamingServer.prefixPiecesReady(
          pieceStates: states,
          firstPiece: 10,
          lastPiece: 19,
          pieceSize: piece,
        ),
        isFalse,
      );
    });

    test('is true once the first piece of the file is downloaded', () {
      final states = List<int>.filled(20, 0);
      states[10] = 2;

      expect(
        LocalStreamingServer.prefixPiecesReady(
          pieceStates: states,
          firstPiece: 10,
          lastPiece: 19,
          pieceSize: piece,
        ),
        isTrue,
      );
    });

    test('does not wait for a second piece that may never complete', () {
      final states = List<int>.filled(20, 0);
      states[10] = 2;

      expect(
        LocalStreamingServer.prefixPiecesReady(
          pieceStates: states,
          firstPiece: 10,
          lastPiece: 19,
          pieceSize: 4 * 1024 * 1024,
          minBytes: 8 * 1024 * 1024,
        ),
        isTrue,
      );
    });

    test('a downloading first piece (state 1) is not ready', () {
      final states = List<int>.filled(5, 1);
      expect(
        LocalStreamingServer.prefixPiecesReady(
          pieceStates: states,
          firstPiece: 0,
          lastPiece: 4,
          pieceSize: piece,
        ),
        isFalse,
      );
    });

    test(
      'prefixPieceIds still returns leading pieces when piece size is unknown',
      () {
        expect(
          LocalStreamingServer.prefixPieceIds(
            firstPiece: 10,
            lastPiece: 19,
            pieceSize: 0,
          ),
          [10, 11, 12, 13],
        );
      },
    );

    test('unknown piece size is ready once the first piece is state 2', () {
      final states = List<int>.filled(20, 0);
      states[10] = 2;
      expect(
        LocalStreamingServer.prefixPiecesReady(
          pieceStates: states,
          firstPiece: 10,
          lastPiece: 19,
          pieceSize: 0,
        ),
        isTrue,
      );
    });
  });
}
