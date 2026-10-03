import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../models/torrent_file.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';
import 'piece_geometry.dart';
import 'torrent_engine.dart';

/// One downloaded region of the streaming file, as a fraction of the whole.
///
/// The seek bar draws these instead of a single 0→progress block. A scalar
/// progress fraction says *how much* is downloaded but not *which parts* —
/// and whenever pieces land out of order those are different questions.
/// Drawing the scalar as a solid bar from zero told the user that everything
/// to its left was playable when it was not, so seeking "into the white"
/// landed in a hole and playback dropped back to the spinner.
@immutable
class BufferedSpan {
  const BufferedSpan(this.start, this.end);

  /// Fraction of the file where this run begins, 0.0–1.0.
  final double start;

  /// Fraction of the file where this run ends, 0.0–1.0.
  final double end;

  @override
  bool operator ==(Object other) =>
      other is BufferedSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() =>
      'BufferedSpan(${start.toStringAsFixed(3)}-${end.toStringAsFixed(3)})';
}

/// What the buffer-headroom check wants done with playback right now.
enum BufferAction {
  /// Ample headroom — leave playback alone.
  none,

  /// Headroom has fallen below the pause threshold; pause and show the
  /// buffering overlay.
  pause,

  /// Headroom has recovered past the resume threshold; resume playback.
  resume,

  /// Still paused and still short of the resume threshold — stay paused and
  /// refresh the overlay so it doesn't look frozen.
  hold,
}

/// Watches the player position against the torrent's downloaded data and
/// intervenes so mpv never reads into not-yet-downloaded regions.
///
/// Two jobs:
/// 1. **Edge tracking** — through the local proxy, pause when playback
///    approaches the end of the downloaded run it is in and resume once
///    enough has landed. Hysteresis (a wide pause/resume band) keeps it from
///    flapping at the boundary.
/// 2. **Stall recovery** — if position stops advancing while supposedly
///    playing a file straight off disk, pause + small back-seek + resume to
///    flush mpv's demuxer. See [shouldRecoverFromStall].
///
/// Extracted from `video_player_screen.dart`, where it lived as eleven fields
/// and six methods on the player's `State`. It is constructor-injected and
/// `Ref`-free — matching `AutoDownloadService` and `LocalStreamingServer` —
/// so the decision logic below can be unit-tested with plain numbers, no
/// `Player` and no engine.
class PlaybackHealthMonitor {
  PlaybackHealthMonitor({
    required Player player,
    required TorrentEngine engine,
    required this.torrentHash,
    required this.fileIndex,
    required this.usingProxy,
    required this.engineHandlesBackpressure,
    required this.isActive,
    required this.onDownloadedRatio,
    required this.onBufferedSpans,
    required this.onBuffering,
    required this.onBufferingResolved,
  }) : _player = player,
       _engine = engine;

  final Player _player;
  final TorrentEngine _engine;

  final String torrentHash;
  final int? fileIndex;

  /// True when mpv reads over HTTP — the local streaming proxy, or the
  /// engine's own stream endpoint — rather than straight off disk. Changes
  /// both how headroom is measured and whether stall recovery applies at all.
  final bool usingProxy;

  /// True when the engine itself serves the stream — it blocks on missing
  /// pieces and prioritises the read head, rather than leaving a
  /// pre-allocated file whose gaps read back as zeros.
  ///
  /// That removes the reason for every intervention this class makes. There
  /// is nothing to pause for (the response simply waits), nothing to recover
  /// from (mpv never sees a zero), and nothing to re-order (the engine
  /// already fetches what is being read). What stays is the *reporting*: the
  /// seek bar's buffered track and the seek-past-head overlay, which are
  /// still the only honest account of what is on disk.
  final bool engineHandlesBackpressure;

  /// Stands in for `State.mounted`. Checked before every callback and after
  /// every await.
  final bool Function() isActive;

  /// Latest 0.0–1.0 download progress for the streaming file. Drives the
  /// buffering overlay's percentage, and the seek bar's buffered track when
  /// no piece map is available.
  final void Function(double ratio) onDownloadedRatio;

  /// Where the downloaded bytes actually are, as fractions of the file.
  /// Empty when the engine won't give us a usable piece map — callers fall
  /// back to [onDownloadedRatio]. See [BufferedSpan].
  final void Function(List<BufferedSpan> spans) onBufferedSpans;

  /// Show the buffering overlay with this message and optional progress.
  final void Function(String message, double? progress) onBuffering;

  /// Dismiss the buffering overlay.
  final VoidCallback onBufferingResolved;

  // ---------------------------------------------------------------------
  // Tunables
  // ---------------------------------------------------------------------

  static const Duration pollInterval = Duration(seconds: 2);

  /// Pause when less than this fraction of the file is downloaded ahead of
  /// the playhead, contiguously. Fractions rather than seconds because the
  /// MKV tail probe is disabled through the proxy and `duration` is
  /// unreliable until mpv has settled.
  ///
  /// For a 4 GB / 45-min episode: pauseBelow ≈ 20 MB / 13 s of headroom;
  /// resumeAbove ≈ 80 MB / 54 s.
  static const double pauseBelowRatio = 0.005;
  static const double resumeAboveRatio = 0.020;

  /// Stall detector: position frozen for at least this long while playing
  /// triggers the pause+back-seek+resume recovery. Originally 4 s, bumped to
  /// 15 s after two real cases where recovery kept firing every cycle and
  /// prevented mpv from finishing what it was already doing:
  ///   • initial open of HEVC 1080p can take 5–10 s while mpv probes and
  ///     primes the decoder;
  ///   • a forward seek to a buffered position similarly needs several
  ///     seconds for mpv to re-key the decoder.
  /// 15 s is well past both legitimate cases but still catches a real freeze.
  static const Duration stallThreshold = Duration(seconds: 15);

  /// Minimum gap between successive stall recoveries. Without this we'd
  /// re-trigger every poll after the previous recovery completed, hammering
  /// mpv with seeks — it may need several seconds to settle before its
  /// position starts advancing again.
  static const Duration minRecoveryGap = Duration(seconds: 12);

  /// How far back to seek when recovering from a stall — far enough that mpv
  /// re-reads from a region that is definitely already on disk.
  static const Duration stallBackSeek = Duration(seconds: 3);

  /// Slack applied to the past-the-head comparison. 1% absorbs VBR jitter so
  /// a few seconds of play near the edge doesn't toggle the indicator.
  ///
  /// Only used on the scalar fallback path. With a piece map we compare
  /// against real byte ranges and the slack is one piece — see
  /// [isOffsetPastBuffer].
  static const double pastHeadSlack = 0.01;

  /// mpv occasionally reports a near-zero duration during initial open,
  /// before the demuxer settles. Ratio maths is meaningless until then.
  static const int minReliableDurationSeconds = 30;

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------

  late final PollLoop _poll = PollLoop(
    name: 'playback-health',
    onTick: _runCheck,
  );
  StreamSubscription<Duration>? _positionSub;

  Duration _lastObservedPosition = Duration.zero;
  DateTime _lastPositionAdvanceAt = DateTime.now();
  DateTime _lastRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _autoBufferPaused = false;
  bool _disposed = false;

  // Where the target file sits in the torrent's pieces. Fixed once the
  // torrent's metadata is in, so resolved on the first poll that can.
  int _fileSizeBytes = 0;
  int _pieceSize = 0;
  FilePieceMap? _pieceMap;

  /// Downloaded runs of the target file, file-relative bytes. Empty when the
  /// engine gave us no usable piece map; every consumer then falls back to
  /// the scalar progress fraction.
  List<ByteRange> _availableRanges = const [];

  /// Set true the first time mpv's position actually advances past zero.
  /// Gates stall detection so recovery doesn't fire during the initial open
  /// window, where position is legitimately frozen at 0.
  bool _hasStartedPlayback = false;

  /// True while the seek-past-head overlay is on screen, so we know to
  /// dismiss it once the buffer catches up.
  bool _seekPastHeadActive = false;

  @visibleForTesting
  bool get autoBufferPaused => _autoBufferPaused;

  // ---------------------------------------------------------------------
  // Pure decision logic — no I/O, unit-testable with plain numbers
  // ---------------------------------------------------------------------

  /// Whether a frozen position warrants the recovery seek.
  ///
  /// Always false when mpv reads over HTTP. The recovery was designed for a
  /// file read straight off disk, where mpv could wedge its decoder on sparse
  /// zeros. Through the proxy or the engine that cannot happen — mpv only
  /// ever receives real bytes, and `paused-for-cache` clears on its own the
  /// moment data flows. Seeking during a normal cache pause actively breaks
  /// playback: it invalidates the decode pipeline mid-prime, the next stall
  /// fires 15 s later, and the loop never ends.
  @visibleForTesting
  static bool shouldRecoverFromStall({
    required bool hasStartedPlayback,
    required bool isPlaying,
    required bool autoBufferPaused,
    required bool usingProxy,
    required bool engineHandlesBackpressure,
    required Duration sinceAdvance,
    required Duration sinceRecovery,
  }) {
    if (usingProxy || engineHandlesBackpressure) return false;
    if (!hasStartedPlayback || !isPlaying || autoBufferPaused) return false;
    return sinceAdvance >= stallThreshold && sinceRecovery >= minRecoveryGap;
  }

  /// Map current headroom onto a playback action.
  ///
  /// [requirePositiveHeadroom] keeps a playhead sitting in a hole — after a
  /// seek past the download — from being treated as "about to run out": that
  /// is the seek-past-head case, handled by its own indicator.
  @visibleForTesting
  static BufferAction decideBufferAction({
    required bool autoBufferPaused,
    required bool isPlaying,
    required double headroom,
    required double pauseBelow,
    required double resumeAbove,
    required bool requirePositiveHeadroom,
  }) {
    if (!autoBufferPaused &&
        isPlaying &&
        (!requirePositiveHeadroom || headroom > 0) &&
        headroom < pauseBelow) {
      return BufferAction.pause;
    }
    if (autoBufferPaused && headroom >= resumeAbove) return BufferAction.resume;
    if (autoBufferPaused) return BufferAction.hold;
    return BufferAction.none;
  }

  /// How much of the file — as a fraction — is downloaded contiguously from
  /// [offset] on: the run the playhead is in, from the playhead to its end.
  ///
  /// Zero when [offset] sits in a hole. Null when there is no piece map to
  /// say, and the caller falls back to overall progress — which is what the
  /// resume decision used to rely on always: after a pause and a forward
  /// seek, playback stayed held until the *whole file's* progress passed the
  /// new position, however much was already on disk right there.
  @visibleForTesting
  static double? headroomAt({
    required List<ByteRange> ranges,
    required int offset,
    required int fileSize,
  }) {
    if (fileSize <= 0 || ranges.isEmpty) return null;
    for (final range in ranges) {
      if (offset >= range.start && offset <= range.end) {
        return (range.end + 1 - offset) / fileSize;
      }
    }
    return 0;
  }

  /// Whether playback has moved past the downloaded region — almost always
  /// because the user seeked into an unbuffered part of the file.
  @visibleForTesting
  static bool isPastDownloadHead({
    required double positionRatio,
    required double fileProgress,
  }) => positionRatio > fileProgress + pastHeadSlack;

  /// Whether [offset] falls outside every downloaded run by more than
  /// [tolerance] bytes.
  ///
  /// The piece-map answer to [isPastDownloadHead], and the one that matches
  /// what the proxy will do: it serves byte N only if N is inside a completed
  /// piece, regardless of how much of the file is downloaded overall.
  /// [tolerance] should be about one piece: the playhead's byte offset is
  /// estimated from position ÷ duration, which variable bitrate makes
  /// approximate, and we would rather miss an edge case than flash the
  /// overlay every time playback crosses a run boundary.
  ///
  /// Returns false for an empty [ranges] — "no piece map" is not evidence of
  /// a hole, and the caller should use the scalar path instead.
  @visibleForTesting
  static bool isOffsetPastBuffer({
    required List<ByteRange> ranges,
    required int offset,
    required int tolerance,
  }) {
    for (final range in ranges) {
      if (offset >= range.start - tolerance &&
          offset <= range.end + tolerance) {
        return false;
      }
    }
    return ranges.isNotEmpty;
  }

  /// Whether any downloaded run extends past [offset].
  ///
  /// Separates the two ways the playhead can end up on un-served bytes:
  ///   * it caught up with the download frontier — nothing is downloaded
  ///     further on, the engine is already fetching exactly the right pieces,
  ///     and the ordinary buffering overlay covers it;
  ///   * it landed in a gap with data beyond it — only possible after a seek.
  @visibleForTesting
  static bool hasDataAfter(List<ByteRange> ranges, int offset) =>
      ranges.any((range) => range.end > offset);

  /// Convert file-relative byte runs into the 0.0–1.0 spans the seek bar
  /// draws.
  @visibleForTesting
  static List<BufferedSpan> toBufferedSpans(
    List<ByteRange> ranges,
    int fileSize,
  ) {
    if (fileSize <= 0) return const [];
    return [
      for (final range in ranges)
        BufferedSpan(
          (range.start / fileSize).clamp(0.0, 1.0),
          ((range.end + 1) / fileSize).clamp(0.0, 1.0),
        ),
    ];
  }

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  /// Begin monitoring. Restart-safe — the player screen calls this both after
  /// the initial open and again after the resume prompt, and every counter is
  /// reset here.
  void start() {
    if (_disposed) return;

    _poll.stop();
    unawaited(_positionSub?.cancel());

    _lastObservedPosition = Duration.zero;
    _lastPositionAdvanceAt = DateTime.now();
    _hasStartedPlayback = false;
    _lastRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);

    // Track when the player position last moved (stall detection input).
    _positionSub = _player.stream.position.listen((pos) {
      final delta = (pos - _lastObservedPosition).inMilliseconds.abs();
      if (delta > 250) {
        _lastObservedPosition = pos;
        _lastPositionAdvanceAt = DateTime.now();
        // First real frame delivered — from now on, a frozen position is a
        // real stall worth recovering from. Before this, position sits at 0
        // because mpv is still loading; recovering would just hammer it.
        if (pos > Duration.zero) _hasStartedPlayback = true;
      }
    });

    // Fire once immediately so the seek-bar's buffered region populates
    // without waiting a full poll interval. The loop never overlaps itself,
    // so a slow tick (or a stall recovery inside one) is simply skipped.
    _poll.start(pollInterval, fireImmediately: true);
  }

  /// Stop monitoring. Synchronous and dependency-free so the player screen can
  /// call it from `dispose()`, where providers may already be torn down.
  void dispose() {
    _disposed = true;
    _poll.dispose();
    unawaited(_positionSub?.cancel());
    _positionSub = null;
  }

  bool get _alive => !_disposed && isActive();

  // ---------------------------------------------------------------------
  // Poll
  // ---------------------------------------------------------------------

  /// Fetch the target file's progress and piece map, push both to the UI,
  /// and hand the file back so the edge checks can reuse it.
  ///
  /// Independent of playback state, so the seek bar keeps filling in while
  /// mpv is still opening and `duration` is still zero.
  ///
  /// Returns null when the file can't be resolved — the caller then skips
  /// edge tracking for this tick rather than acting on stale numbers.
  Future<TorrentFile?> _refreshDownloadState() async {
    final idx = fileIndex;
    if (idx == null) return null;

    final files = await _engine.tryGetTorrentFiles(torrentHash);
    if (!_alive || files == null || idx < 0 || idx >= files.length) {
      return null;
    }

    final file = files[idx];
    if (file.size <= 0) return null;

    _fileSizeBytes = file.size;
    onDownloadedRatio(file.progress);

    await _refreshPieceMap(files, idx);
    return _alive ? file : null;
  }

  /// Resolve the file's piece geometry (once) and re-read piece states,
  /// converting them into the byte runs the seek bar draws and the edge
  /// checks use.
  ///
  /// Every failure here is soft: [_availableRanges] simply stays as it was
  /// and consumers fall back to scalar progress.
  Future<void> _refreshPieceMap(List<TorrentFile> files, int idx) async {
    try {
      if (_pieceSize <= 0) _pieceSize = await _engine.getPieceSize(torrentHash);
      if (_pieceSize <= 0 || !_alive) return;

      final map = _pieceMap ??= PieceGeometry.forFile(
        files: files,
        fileIndex: idx,
        pieceSize: _pieceSize,
      );
      if (map == null) return;

      final states = await _engine.getPieceStates(torrentHash);
      if (!_alive || states == null || states.isEmpty) return;

      _availableRanges = map.availableRanges(states);
      onBufferedSpans(toBufferedSpans(_availableRanges, _fileSizeBytes));
    } catch (e) {
      AppLog.e('[HealthMonitor] Piece-map poll failed: $e');
    }
  }

  Future<void> _runCheck() async {
    if (!_alive) return;

    final isPlaying = _player.state.playing;
    final position = _player.state.position;
    final duration = _player.state.duration;

    // Report download progress before anything else bails out.
    //
    // Everything below needs a duration to reason about — but the seek bar's
    // buffered track does not, and it is exactly while mpv is still settling
    // (duration still 0) that the user most wants to see the file filling up.
    final file = await _refreshDownloadState();
    if (!_alive) return;

    if (duration.inMilliseconds <= 0) return;

    // 1) Stall detection.
    final now = DateTime.now();
    if (shouldRecoverFromStall(
      hasStartedPlayback: _hasStartedPlayback,
      isPlaying: isPlaying,
      autoBufferPaused: _autoBufferPaused,
      usingProxy: usingProxy,
      engineHandlesBackpressure: engineHandlesBackpressure,
      sinceAdvance: now.difference(_lastPositionAdvanceAt),
      sinceRecovery: now.difference(_lastRecoveryAt),
    )) {
      AppLog.w(
        '[HealthMonitor] Stall detected — position frozen for '
        '${now.difference(_lastPositionAdvanceAt).inSeconds}s. Recovering.',
      );
      _lastRecoveryAt = now;
      await _recoverFromStall();
      return;
    }

    // 2) Edge tracking. Reuses the file resolved above.
    if (file == null) return;
    try {
      // File is done — nothing useful left to pause for.
      if (file.isComplete) {
        if (_autoBufferPaused) {
          _autoBufferPaused = false;
          await _player.play();
        }
        if (_seekPastHeadActive) {
          _seekPastHeadActive = false;
          onBufferingResolved();
        }
        return;
      }

      _updateSeekPastHeadIndicator(
        position: position,
        duration: duration,
        fileProgress: file.progress,
      );

      // Through the engine's own endpoint, or straight off a finished file,
      // there is nothing to pause for — only the reporting above.
      if (engineHandlesBackpressure || !usingProxy) return;

      await _runProxyEdgeCheck(
        position: position,
        duration: duration,
        fileProgress: file.progress,
        isPlaying: isPlaying,
      );
    } catch (e) {
      AppLog.e('[HealthMonitor] Health check error: $e');
    }
  }

  Future<void> _runProxyEdgeCheck({
    required Duration position,
    required Duration duration,
    required double fileProgress,
    required bool isPlaying,
  }) async {
    if (duration.inSeconds < minReliableDurationSeconds) return;

    if (_autoBufferPaused && isPlaying) {
      // The user pressed play while we were holding. Their call: stop
      // holding, and take the overlay down with it — it used to stay up over
      // a playing video. If the data really is not there, the check below
      // pauses again with a fresh reason.
      _autoBufferPaused = false;
      if (!_seekPastHeadActive) onBufferingResolved();
    }

    final positionRatio = position.inMilliseconds / duration.inMilliseconds;
    final offset = (_fileSizeBytes * positionRatio).round();
    final headroom =
        headroomAt(
          ranges: _availableRanges,
          offset: offset,
          fileSize: _fileSizeBytes,
        ) ??
        fileProgress - positionRatio;

    final action = decideBufferAction(
      autoBufferPaused: _autoBufferPaused,
      isPlaying: isPlaying,
      headroom: headroom,
      pauseBelow: pauseBelowRatio,
      resumeAbove: resumeAboveRatio,
      requirePositiveHeadroom: true,
    );

    switch (action) {
      case BufferAction.pause:
        AppLog.d(
          '[HealthMonitor] proxy pause — headroom '
          '${(headroom * 100).toStringAsFixed(2)}% '
          '< ${(pauseBelowRatio * 100).toStringAsFixed(1)}%',
        );
        _autoBufferPaused = true;
        await _player.pause();
        if (!_alive) return;
        onBuffering('Buffering…', fileProgress);
      case BufferAction.resume:
        AppLog.d(
          '[HealthMonitor] proxy resume — headroom '
          '${(headroom * 100).toStringAsFixed(2)}% '
          '>= ${(resumeAboveRatio * 100).toStringAsFixed(1)}%',
        );
        _autoBufferPaused = false;
        onBufferingResolved();
        _lastPositionAdvanceAt = DateTime.now();
        await _player.play();
      case BufferAction.hold:
        // Live progress while paused so the overlay doesn't look frozen.
        // Suppressed when the seek-past-head indicator owns the overlay.
        if (_seekPastHeadActive) return;
        onBuffering('Buffering…', fileProgress);
      case BufferAction.none:
        break;
    }
  }

  /// Detect playback sitting on bytes that are not downloaded because the
  /// user seeked there, and say so — otherwise it looks like a generic
  /// spinner.
  ///
  /// For an engine whose download order the caller drives (qBittorrent),
  /// also make sure sequential download is on. It is the only ordering
  /// control qBittorrent's Web API has: there is no per-piece priority, so
  /// nothing can point it at the playhead directly. This used to turn
  /// sequential *off* after a forward seek and then ask for the pieces around
  /// the playhead through an endpoint that does not exist — leaving the rest
  /// of the file downloading rarest-first with nothing aimed at the playhead.
  void _updateSeekPastHeadIndicator({
    required Duration position,
    required Duration duration,
    required double fileProgress,
  }) {
    if (duration.inSeconds < minReliableDurationSeconds) return;

    final positionRatio = position.inMilliseconds / duration.inMilliseconds;
    final offset = (_fileSizeBytes * positionRatio).round();
    final haveMap = _availableRanges.isNotEmpty && _pieceSize > 0;

    // Is the playhead actually on bytes that can be served? The piece map
    // answers this exactly; comparing against a scalar `fileProgress` only
    // works while pieces arrive in order. A position well *under*
    // `fileProgress` can still sit in a gap — which is what a seek "into the
    // white part of the bar" looked like: a generic, unexplained stall.
    final inHole = haveMap
        ? isOffsetPastBuffer(
            ranges: _availableRanges,
            offset: offset,
            tolerance: _pieceSize,
          )
        : isPastDownloadHead(
            positionRatio: positionRatio,
            fileProgress: fileProgress,
          );

    // …and if so, is it a seek, or has playback merely caught up with the
    // download frontier? Only the first is this method's business — at the
    // frontier the engine is already fetching precisely the right pieces and
    // the ordinary buffering overlay explains the wait.
    final pastFrontier = isPastDownloadHead(
      positionRatio: positionRatio,
      fileProgress: fileProgress,
    );
    final seekedIntoHole =
        inHole &&
        (pastFrontier || (haveMap && hasDataAfter(_availableRanges, offset)));

    if (seekedIntoHole) {
      if (!_seekPastHeadActive && _engine.capabilities.pieceLevelControl) {
        unawaited(_keepSequentialOn());
      }
      _seekPastHeadActive = true;
      onBuffering('Loading this part of the video…', fileProgress);
    } else if (_seekPastHeadActive) {
      _seekPastHeadActive = false;
      onBufferingResolved();
    }
  }

  Future<void> _keepSequentialOn() async {
    try {
      final ok = await _engine.ensureInOrderDownload(torrentHash);
      AppLog.d('[HealthMonitor] seek past the download — sequential on: $ok');
    } catch (e) {
      AppLog.w('[HealthMonitor] could not check sequential download: $e');
    }
  }

  Future<void> _recoverFromStall() async {
    try {
      final pos = _player.state.position;

      // Pause first so mpv stops trying to decode garbage.
      await _player.pause();

      // Force mpv to flush its demuxer cache and re-read fresh data. A few
      // seconds in, a back-seek into known-good (already played) territory
      // works. Near the start of the file — the typical "opens but never
      // plays" case — seeking back to 0 when already at 0 is a no-op for
      // mpv, so probe forward by 1 s and return. Either path forces a
      // demuxer flush and clears `paused-for-cache`.
      Duration resumeFrom;
      if (pos < stallBackSeek) {
        await _player.seek(pos + const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (!_alive) return;
        await _player.seek(pos);
        resumeFrom = pos;
      } else {
        final target = pos - stallBackSeek;
        final clamped = target.isNegative ? Duration.zero : target;
        await _player.seek(clamped);
        resumeFrom = clamped;
      }

      // Give mpv a moment to re-prime the demuxer before resuming.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!_alive) return;

      _lastObservedPosition = resumeFrom;
      _lastPositionAdvanceAt = DateTime.now();
      await _player.play();
    } catch (e) {
      AppLog.e('[HealthMonitor] Stall recovery failed: $e');
    }
  }
}
