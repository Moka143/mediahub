import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_torrent_client/services/local_streaming_server.dart';

/// Matches the private `_tailProbeWindow` on the server (64 MB).
const _tailProbeWindow = 64 * 1024 * 1024;

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

    test('every offset of a sub-window file counts as a tail probe', () {
      // The window is absolute, so a file smaller than 64 MB never reaches
      // the blocking-read path — it always fast-fails with a 416 instead.
      const tenMb = 10 * 1024 * 1024;

      expect(LocalStreamingServer.isTailProbeStart(0, tenMb), isTrue);
      expect(LocalStreamingServer.isTailProbeStart(tenMb - 1, tenMb), isTrue);
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
}
