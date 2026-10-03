import 'package:flutter_test/flutter_test.dart';

import 'package:mediahub/services/piece_geometry.dart';
import 'package:mediahub/services/playback_health_monitor.dart';

void main() {
  group('shouldRecoverFromStall', () {
    // Baseline: a genuinely wedged direct-disk playback.
    bool call({
      bool hasStartedPlayback = true,
      bool isPlaying = true,
      bool autoBufferPaused = false,
      bool usingProxy = false,
      bool engineHandlesBackpressure = false,
      Duration sinceAdvance = const Duration(seconds: 20),
      Duration sinceRecovery = const Duration(seconds: 60),
    }) => PlaybackHealthMonitor.shouldRecoverFromStall(
      hasStartedPlayback: hasStartedPlayback,
      isPlaying: isPlaying,
      autoBufferPaused: autoBufferPaused,
      usingProxy: usingProxy,
      engineHandlesBackpressure: engineHandlesBackpressure,
      sinceAdvance: sinceAdvance,
      sinceRecovery: sinceRecovery,
    );

    test('recovers a frozen direct-disk playback', () {
      expect(call(), isTrue);
    });

    test('never recovers in proxy mode', () {
      // Recovery seeks during a normal cache pause invalidate mpv's decode
      // pipeline mid-prime and the stall re-fires forever. The proxy makes
      // the original wedge impossible, so this path must stay off.
      expect(call(usingProxy: true), isFalse);
    });

    test('never recovers when the engine serves the stream', () {
      // Same reasoning as proxy mode, one step further: mpv only ever
      // receives bytes the engine hands it, so a frozen position is a cache
      // pause and seeking into one breaks the decode pipeline mid-prime.
      expect(call(engineHandlesBackpressure: true), isFalse);
    });

    test('waits for the first real frame before arming', () {
      expect(call(hasStartedPlayback: false), isFalse);
    });

    test('ignores a paused player', () {
      expect(call(isPlaying: false), isFalse);
    });

    test('ignores a pause we initiated ourselves for buffering', () {
      expect(call(autoBufferPaused: true), isFalse);
    });

    test('holds off until the stall threshold', () {
      expect(call(sinceAdvance: PlaybackHealthMonitor.stallThreshold), isTrue);
      expect(
        call(
          sinceAdvance:
              PlaybackHealthMonitor.stallThreshold -
              const Duration(milliseconds: 1),
        ),
        isFalse,
      );
    });

    test('rate-limits back-to-back recoveries', () {
      expect(call(sinceRecovery: PlaybackHealthMonitor.minRecoveryGap), isTrue);
      expect(
        call(
          sinceRecovery:
              PlaybackHealthMonitor.minRecoveryGap -
              const Duration(milliseconds: 1),
        ),
        isFalse,
      );
    });
  });

  group('decideBufferAction — proxy (file fraction)', () {
    BufferAction call({
      required bool autoBufferPaused,
      bool isPlaying = true,
      required double headroom,
    }) => PlaybackHealthMonitor.decideBufferAction(
      autoBufferPaused: autoBufferPaused,
      isPlaying: isPlaying,
      headroom: headroom,
      pauseBelow: PlaybackHealthMonitor.pauseBelowRatio,
      resumeAbove: PlaybackHealthMonitor.resumeAboveRatio,
      requirePositiveHeadroom: true,
    );

    test('pauses inside the low band', () {
      expect(
        call(autoBufferPaused: false, headroom: 0.002),
        BufferAction.pause,
      );
    });

    test('does not pause on negative headroom', () {
      // Negative headroom means the user seeked past the download edge. That
      // is the seek-past-head indicator's job, not a buffering pause.
      expect(call(autoBufferPaused: false, headroom: -0.05), BufferAction.none);
    });

    test('resumes only past the upper ratio', () {
      expect(
        call(autoBufferPaused: true, headroom: 0.020),
        BufferAction.resume,
      );
      expect(call(autoBufferPaused: true, headroom: 0.019), BufferAction.hold);
    });
  });

  group('isPastDownloadHead', () {
    test('allows slack for VBR jitter near the edge', () {
      // 1% of slack, so brushing the edge does not toggle the indicator.
      expect(
        PlaybackHealthMonitor.isPastDownloadHead(
          positionRatio: 0.505,
          fileProgress: 0.50,
        ),
        isFalse,
      );
      expect(
        PlaybackHealthMonitor.isPastDownloadHead(
          positionRatio: 0.52,
          fileProgress: 0.50,
        ),
        isTrue,
      );
    });

    test('is false well inside the downloaded region', () {
      expect(
        PlaybackHealthMonitor.isPastDownloadHead(
          positionRatio: 0.10,
          fileProgress: 0.80,
        ),
        isFalse,
      );
    });
  });

  group('headroomAt', () {
    const mb = 1024 * 1024;
    const fileSize = 100 * mb;
    const ranges = [ByteRange(0, 20 * mb - 1), ByteRange(60 * mb, 80 * mb - 1)];

    double? at(int offset, [List<ByteRange> r = ranges]) =>
        PlaybackHealthMonitor.headroomAt(
          ranges: r,
          offset: offset,
          fileSize: fileSize,
        );

    test('is the rest of the run the playhead is in', () {
      expect(at(10 * mb), closeTo(0.10, 1e-9));
      expect(at(70 * mb), closeTo(0.10, 1e-9));
    });

    test('a forward seek into a downloaded run resumes on what is there', () {
      // The case overall progress got wrong: 40% downloaded overall, the
      // playhead at 60% — but 20% of data sits right under it.
      expect(at(60 * mb), closeTo(0.20, 1e-9));
    });

    test('is zero in a hole', () {
      expect(at(40 * mb), 0);
    });

    test('is null with no piece map, so the caller falls back', () {
      expect(at(10 * mb, const []), isNull);
      expect(
        PlaybackHealthMonitor.headroomAt(
          ranges: ranges,
          offset: 0,
          fileSize: 0,
        ),
        isNull,
      );
    });
  });

  group('isOffsetPastBuffer', () {
    const mb = 1024 * 1024;
    // 50% of the file downloaded, but scattered — the exact shape that makes
    // a scalar progress fraction lie.
    const scattered = [
      ByteRange(0, 20 * mb - 1),
      ByteRange(60 * mb, 80 * mb - 1),
    ];

    test('a position inside a run is not past the buffer', () {
      expect(
        PlaybackHealthMonitor.isOffsetPastBuffer(
          ranges: scattered,
          offset: 10 * mb,
          tolerance: 0,
        ),
        isFalse,
      );
      expect(
        PlaybackHealthMonitor.isOffsetPastBuffer(
          ranges: scattered,
          offset: 70 * mb,
          tolerance: 0,
        ),
        isFalse,
      );
    });

    test('a position in a hole is past the buffer', () {
      // 40 MB is under the 50% "downloaded" mark, so the scalar check would
      // call this fine — and the proxy would block on it.
      expect(
        PlaybackHealthMonitor.isOffsetPastBuffer(
          ranges: scattered,
          offset: 40 * mb,
          tolerance: 0,
        ),
        isTrue,
      );
    });

    test('tolerance absorbs the piece-boundary approximation', () {
      // availableRanges assumes the file starts on a piece boundary, so a
      // run edge can be off by up to one piece. Playback crossing that edge
      // must not flash the overlay.
      expect(
        PlaybackHealthMonitor.isOffsetPastBuffer(
          ranges: scattered,
          offset: 20 * mb + 1024,
          tolerance: 4 * mb,
        ),
        isFalse,
      );
      expect(
        PlaybackHealthMonitor.isOffsetPastBuffer(
          ranges: scattered,
          offset: 40 * mb,
          tolerance: 4 * mb,
        ),
        isTrue,
        reason: 'tolerance must not swallow a real hole',
      );
    });

    test('no piece map is not evidence of a hole', () {
      expect(
        PlaybackHealthMonitor.isOffsetPastBuffer(
          ranges: const [],
          offset: 40 * mb,
          tolerance: 0,
        ),
        isFalse,
      );
    });
  });

  group('hasDataAfter', () {
    const mb = 1024 * 1024;

    test('a gap with data beyond it is a seek, not the frontier', () {
      expect(
        PlaybackHealthMonitor.hasDataAfter(const [
          ByteRange(0, 20 * mb - 1),
          ByteRange(60 * mb, 80 * mb - 1),
        ], 40 * mb),
        isTrue,
      );
    });

    test('nothing downloaded past the playhead is the frontier', () {
      // Playback caught up with a sequential download. Sequential is already
      // fetching the right pieces, so this must not be treated as a seek.
      expect(
        PlaybackHealthMonitor.hasDataAfter(const [
          ByteRange(0, 20 * mb - 1),
        ], 20 * mb + 1),
        isFalse,
      );
    });

    test('no piece map means no claim either way', () {
      expect(PlaybackHealthMonitor.hasDataAfter(const [], 10 * mb), isFalse);
    });
  });

  group('toBufferedSpans', () {
    test('maps byte runs onto fractions of the file', () {
      final spans = PlaybackHealthMonitor.toBufferedSpans(const [
        ByteRange(0, 249),
        ByteRange(500, 999),
      ], 1000);

      expect(spans, const [BufferedSpan(0.0, 0.25), BufferedSpan(0.5, 1.0)]);
    });

    test('a zero-size file yields nothing rather than dividing by zero', () {
      expect(
        PlaybackHealthMonitor.toBufferedSpans(const [ByteRange(0, 9)], 0),
        isEmpty,
      );
    });
  });
}
