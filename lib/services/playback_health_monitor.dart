import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../models/torrent_file.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';
import 'local_streaming_server.dart';
import 'torrent_engine.dart';

/// One downloaded region of the streaming file, as a fraction of the whole.
///
/// The seek bar draws these instead of a single 0→progress block. A scalar
/// progress fraction says *how much* is downloaded but not *which parts* —
/// and once the piece picker stops running in order (which is exactly what
/// we do after a seek) those are different questions. Drawing the scalar as
/// a solid bar from zero told the user that everything to its left was
/// playable when it was not, so seeking "into the white" landed in a hole
/// and playback dropped back to the spinner.
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

/// Watches the player position against the torrent's download edge and
/// intervenes so mpv never reads into not-yet-downloaded regions.
///
/// Two jobs:
/// 1. **Edge tracking** — pause when playback approaches the download edge,
///    resume once enough has landed. Hysteresis (a wide pause/resume band)
///    keeps it from flapping at the boundary.
/// 2. **Stall recovery** — if position stops advancing while supposedly
///    playing, pause + small back-seek + resume to flush mpv's demuxer.
///    Only relevant on the legacy direct-disk path; see
///    [shouldRecoverFromStall].
///
/// Extracted from `video_player_screen.dart`, where it lived as eleven fields
/// and six methods on the player's `State`. It is constructor-injected and
/// `Ref`-free — matching `AutoDownloadService` and `LocalStreamingServer` —
/// so the decision logic below can be unit-tested with plain numbers, no
/// `Player` and no qBittorrent instance.
class PlaybackHealthMonitor {
  PlaybackHealthMonitor({
    required Player player,
    required TorrentEngine qbt,
    required this.torrentHash,
    required this.fileIndex,
    required this.usingProxy,
    required this.isActive,
    required this.onDownloadedRatio,
    required this.onBufferedSpans,
    required this.onBuffering,
    required this.onBufferingResolved,
  }) : _player = player,
       _qbt = qbt;

  final Player _player;
  final TorrentEngine _qbt;

  final String torrentHash;
  final int? fileIndex;

  /// True when playback is served through [LocalStreamingServer] rather than
  /// straight off disk. Changes both the headroom units and whether stall
  /// recovery applies at all.
  final bool usingProxy;

  /// Stands in for `State.mounted`. Checked before every callback and after
  /// every await.
  final bool Function() isActive;

  /// Latest 0.0–1.0 download progress for the streaming file. Drives the
  /// buffering overlay's percentage, and the seek bar's buffered track when
  /// no piece map is available.
  final void Function(double ratio) onDownloadedRatio;

  /// Where the downloaded bytes actually are, as fractions of the file.
  /// Empty when qBittorrent won't give us a usable piece map — callers fall
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

  /// Pause when fewer than this many seconds of *download* are buffered ahead
  /// of the player position. Direct-disk path only.
  static const double pauseBelowSecondsAhead = 8.0;

  /// Resume only after the buffer ahead has grown to this much — prevents
  /// immediate re-pause flapping at the boundary.
  static const double resumeAboveSecondsAhead = 25.0;

  /// Proxy-mode equivalents, in file-fraction units. We can't use
  /// seconds-ahead there because the MKV tail probe is disabled and
  /// `duration` is unreliable until mpv has settled.
  ///
  /// For a 4 GB / 45-min episode: pauseBelow ≈ 20 MB / 13 s of headroom;
  /// resumeAbove ≈ 80 MB / 54 s.
  static const double pauseBelowRatio = 0.005;
  static const double resumeAboveRatio = 0.020;

  /// Stall detector: position frozen for at least this long while playing
  /// triggers the pause+back-seek+resume recovery. Originally 4 s, bumped to
  /// 15 s after two real cases where recovery kept firing every cycle and
  /// prevented mpv from finishing what it was already doing:
  ///   • initial open of HEVC 1080p over the HTTP proxy can take 5–10 s
  ///     while mpv probes + primes the decoder;
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

  /// How much of the file to pull at max priority around a seek target.
  /// Roughly 20–30 s of a 1080p episode: enough that playback survives while
  /// the piece picker catches up, small enough not to re-prioritise half the
  /// torrent on every scrub.
  static const int seekPrefetchBytes = 32 * 1024 * 1024; // 32 MB

  /// Don't re-issue piece priorities until the seek target has moved at
  /// least this far. A drag that settles a few seconds away from the last
  /// target is the same request, and qBittorrent's piecePrio endpoint is not
  /// free.
  static const int seekPrefetchResendBytes = 8 * 1024 * 1024; // 8 MB

  /// mpv occasionally reports a near-zero duration during initial open,
  /// before the demuxer settles. Ratio maths is meaningless until then.
  static const int minReliableDurationSeconds = 30;

  /// Treat the file as complete at this point — nothing useful left to pause
  /// for.
  static const double completeEnough = 0.995;

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
  bool _recoveryInFlight = false;
  bool _checkInFlight = false;
  bool _disposed = false;

  // Piece geometry for the target file. Immutable once the torrent is added,
  // so resolved on the first poll that can and then reused.
  int _fileSizeBytes = 0;
  int? _pieceSize;
  int? _firstPiece;
  int? _lastPiece;

  /// Downloaded runs of the target file, file-relative bytes. Empty when
  /// qBittorrent gave us no usable piece map; every consumer then falls back
  /// to the scalar progress fraction.
  List<ByteRange> _availableRanges = const [];

  /// Byte offset of the last seek target handed to qBittorrent's piece
  /// prioritiser, so a scrub that settles nearby doesn't re-issue it.
  int? _lastSeekPrefetchOffset;

  /// Set true the first time mpv's position actually advances past zero.
  /// Gates stall detection so recovery doesn't fire during the initial open
  /// window, where position is legitimately frozen at 0.
  bool _hasStartedPlayback = false;

  /// True while the seek-past-head overlay is on screen, so we know to
  /// dismiss it once the buffer catches up.
  bool _seekPastHeadActive = false;

  /// One-shot per session. Sequential download means "always pull from the
  /// front", which would force the user to wait for the entire intermediate
  /// region after seeking past the edge. Once flipped off we leave it off.
  bool _sequentialDisabledForSeek = false;

  @visibleForTesting
  bool get autoBufferPaused => _autoBufferPaused;

  // ---------------------------------------------------------------------
  // Pure decision logic — no I/O, unit-testable with plain numbers
  // ---------------------------------------------------------------------

  /// Whether a frozen position warrants the recovery seek.
  ///
  /// Always false in proxy mode. The recovery was designed for the direct-disk
  /// path, where mpv could wedge its decoder on sparse zeros. Through the
  /// proxy that cannot happen — mpv only ever receives bytes the proxy hands
  /// it, and `paused-for-cache` clears on its own the moment data flows.
  /// Seeking during a normal cache pause actively breaks playback: it
  /// invalidates the decode pipeline mid-prime, the next stall fires 15 s
  /// later, and the loop never ends.
  @visibleForTesting
  static bool shouldRecoverFromStall({
    required bool hasStartedPlayback,
    required bool isPlaying,
    required bool autoBufferPaused,
    required bool usingProxy,
    required Duration sinceAdvance,
    required Duration sinceRecovery,
  }) {
    if (usingProxy) return false;
    if (!hasStartedPlayback || !isPlaying || autoBufferPaused) return false;
    return sinceAdvance >= stallThreshold && sinceRecovery >= minRecoveryGap;
  }

  /// Map current headroom onto a playback action.
  ///
  /// [requirePositiveHeadroom] guards the proxy path, where negative headroom
  /// means the user seeked past the download edge — that is the seek-past-head
  /// case and is handled by its own indicator, not by pausing.
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
  /// The piece-map answer to [isPastDownloadHead], and the one that actually
  /// matches what the proxy will do: it serves byte N only if N is inside a
  /// completed piece, regardless of how much of the file is downloaded
  /// overall. [tolerance] should be one piece — [availableRanges] assumes the
  /// file starts on a piece boundary, so a run's edges can be off by that
  /// much, and we would rather miss an edge case than flash the overlay
  /// every time playback crosses a run boundary.
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
  ///     further on, sequential is already fetching exactly the right pieces,
  ///     and the ordinary buffering overlay covers it;
  ///   * it landed in a gap with data beyond it — only possible after a seek,
  ///     and the piece picker needs to be told to come back for those pieces.
  @visibleForTesting
  static bool hasDataAfter(List<ByteRange> ranges, int offset) =>
      ranges.any((range) => range.end > offset);

  /// Piece ids covering [spanBytes] of the file forward from [offset],
  /// clamped to the file's own pieces.
  ///
  /// Handed to qBittorrent's piece prioritiser after a seek into an
  /// un-downloaded region. Turning sequential download off lets the picker
  /// leave the head; this is what tells it where to go instead.
  @visibleForTesting
  static List<int> seekTargetPieceIds({
    required int offset,
    required int firstPiece,
    required int lastPiece,
    required int pieceSize,
    int spanBytes = seekPrefetchBytes,
  }) {
    if (pieceSize <= 0 || firstPiece < 0 || lastPiece < firstPiece) {
      return const [];
    }
    final safeOffset = offset < 0 ? 0 : offset;
    final startPiece = (firstPiece + safeOffset ~/ pieceSize).clamp(
      firstPiece,
      lastPiece,
    );
    final available = lastPiece - startPiece + 1;
    final need = (spanBytes / pieceSize).ceil().clamp(1, available).toInt();
    return [for (var i = 0; i < need; i++) startPiece + i];
  }

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

  /// Approximate seconds of downloaded data ahead of the playback position,
  /// assuming a uniform bitrate. Good enough for the 8 s / 25 s hysteresis
  /// band on the direct-disk path.
  @visibleForTesting
  static double secondsAheadOfPosition({
    required int fileSizeBytes,
    required double fileProgress,
    required double positionRatio,
    required int durationSeconds,
  }) {
    if (fileSizeBytes <= 0 || durationSeconds <= 0) return 0;
    final bytesAtPosition = (fileSizeBytes * positionRatio).round();
    final bytesAvailable = (fileSizeBytes * fileProgress).round();
    final bytesAhead = bytesAvailable - bytesAtPosition;
    final avgBytesPerSecond = fileSizeBytes / durationSeconds;
    if (avgBytesPerSecond <= 0) return 0;
    return bytesAhead / avgBytesPerSecond;
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
    _lastSeekPrefetchOffset = null;

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
    // without waiting a full poll interval.
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

    List<TorrentFile> files;
    try {
      files = await _qbt.getTorrentFiles(torrentHash);
    } catch (e) {
      AppLog.e('[HealthMonitor] Download-state poll failed: $e');
      return null;
    }
    if (!_alive || idx < 0 || idx >= files.length) return null;

    final file = files[idx];
    if (file.size <= 0) return null;

    _fileSizeBytes = file.size;
    onDownloadedRatio(file.progress);

    await _refreshPieceMap(files, idx);
    return _alive ? file : null;
  }

  /// Resolve piece geometry (once) and re-read piece states, converting them
  /// into the byte runs the seek bar draws and the past-buffer check uses.
  ///
  /// Every failure here is soft: [_availableRanges] simply stays as it was
  /// and consumers fall back to scalar progress.
  Future<void> _refreshPieceMap(List<TorrentFile> files, int idx) async {
    try {
      if (_pieceSize == null) {
        final size = await _qbt.getPieceSize(torrentHash);
        if (size > 0) _pieceSize = size;
      }
      final pieceSize = _pieceSize;
      if (pieceSize == null || !_alive) return;

      if (_firstPiece == null || _lastPiece == null) {
        // `piece_range` is missing on some WebUI versions; reconstruct it
        // from file sizes the same way the proxy does.
        final listed = files[idx].pieceRange;
        if (listed != null && listed.length >= 2) {
          _firstPiece = listed[0];
          _lastPiece = listed[1];
        } else {
          final computed = LocalStreamingServer.pieceRangeForFile(
            fileSizes: files.map((f) => f.size).toList(),
            fileIndex: idx,
            pieceSize: pieceSize,
          );
          if (computed != null) {
            _firstPiece = computed.$1;
            _lastPiece = computed.$2;
          }
        }
      }
      final first = _firstPiece;
      final last = _lastPiece;
      if (first == null || last == null) return;

      final states = await _qbt.getPieceStates(torrentHash);
      if (!_alive || states == null || states.isEmpty) return;

      _availableRanges = LocalStreamingServer.availableRanges(
        pieceStates: states,
        firstPiece: first,
        lastPiece: last,
        pieceSize: pieceSize,
        fileSize: _fileSizeBytes,
      );
      onBufferedSpans(toBufferedSpans(_availableRanges, _fileSizeBytes));
    } catch (e) {
      AppLog.e('[HealthMonitor] Piece-map poll failed: $e');
    }
  }

  Future<void> _runCheck() async {
    if (!_alive || _recoveryInFlight || _checkInFlight) return;
    _checkInFlight = true;
    try {
      await _runCheckInner();
    } finally {
      _checkInFlight = false;
    }
  }

  Future<void> _runCheckInner() async {
    final isPlaying = _player.state.playing;
    final position = _player.state.position;
    final duration = _player.state.duration;

    // Report download progress before anything else bails out.
    //
    // Everything below needs a duration to reason about — but the seek bar's
    // buffered track does not, and it is exactly while mpv is still settling
    // (duration still 0) that the user most wants to see the file filling up.
    // Reporting after the duration guard meant the indicator sat frozen at
    // whatever it was seeded with for the entire open, and stayed frozen
    // forever if mpv never resolved a duration at all.
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

    // 2) Edge tracking. Reuses the file resolved above — this used to issue
    // a second `getTorrentFiles` for the same data on every tick.
    if (file == null) return;
    try {
      final fileSize = file.size;
      final fileProgress = file.progress;

      // File is done — nothing useful left to pause for.
      if (fileProgress >= completeEnough) {
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

      if (usingProxy) {
        await _runProxyEdgeCheck(
          position: position,
          duration: duration,
          fileProgress: fileProgress,
          isPlaying: isPlaying,
        );
        return;
      }

      await _runDirectEdgeCheck(
        position: position,
        duration: duration,
        fileSize: fileSize,
        fileProgress: fileProgress,
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
    _updateSeekPastHeadIndicator(
      position: position,
      duration: duration,
      fileProgress: fileProgress,
    );

    if (duration.inSeconds < minReliableDurationSeconds) return;

    final positionRatio = position.inMilliseconds / duration.inMilliseconds;
    final headroom = fileProgress - positionRatio;

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
        onBuffering('Buffering — waiting for download…', fileProgress);
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
        final pct = (headroom.clamp(0.0, resumeAboveRatio) * 100)
            .toStringAsFixed(1);
        final target = (resumeAboveRatio * 100).toStringAsFixed(1);
        onBuffering('Buffering — $pct% / $target% ahead', fileProgress);
      case BufferAction.none:
        break;
    }
  }

  Future<void> _runDirectEdgeCheck({
    required Duration position,
    required Duration duration,
    required int fileSize,
    required double fileProgress,
    required bool isPlaying,
  }) async {
    final secondsAhead = secondsAheadOfPosition(
      fileSizeBytes: fileSize,
      fileProgress: fileProgress,
      positionRatio: position.inMilliseconds / duration.inMilliseconds,
      durationSeconds: duration.inSeconds,
    );

    final action = decideBufferAction(
      autoBufferPaused: _autoBufferPaused,
      isPlaying: isPlaying,
      headroom: secondsAhead,
      pauseBelow: pauseBelowSecondsAhead,
      resumeAbove: resumeAboveSecondsAhead,
      requirePositiveHeadroom: false,
    );

    switch (action) {
      case BufferAction.pause:
        AppLog.d(
          '[HealthMonitor] Pre-empt pause — only '
          '${secondsAhead.toStringAsFixed(1)}s buffered ahead.',
        );
        _autoBufferPaused = true;
        await _player.pause();
        if (!_alive) return;
        onBuffering('Buffering — waiting for download…', fileProgress);
      case BufferAction.resume:
        AppLog.d(
          '[HealthMonitor] Resume — '
          '${secondsAhead.toStringAsFixed(1)}s buffered ahead.',
        );
        _autoBufferPaused = false;
        onBufferingResolved();
        // Reset the stall timer so the position-advance check doesn't fire
        // immediately after resume — mpv takes a moment to start ticking.
        _lastPositionAdvanceAt = DateTime.now();
        await _player.play();
      case BufferAction.hold:
        final secs = secondsAhead.clamp(0.0, resumeAboveSecondsAhead).round();
        onBuffering(
          'Buffering — $secs/${resumeAboveSecondsAhead.round()}s ahead',
          fileProgress,
        );
      case BufferAction.none:
        break;
    }
  }

  /// In proxy mode, detect when playback is past the download edge (a user
  /// seek into the unbuffered region) and:
  ///
  ///   1. Disable sequential download the first time it happens, so
  ///      qBittorrent's piece picker can fetch pieces around the seek target
  ///      instead of grinding sequentially from the head.
  ///   2. Surface an overlay so the user knows what's happening — the proxy
  ///      will serve bytes as qBittorrent writes them, but without this it
  ///      just looks like a generic spinner.
  void _updateSeekPastHeadIndicator({
    required Duration position,
    required Duration duration,
    required double fileProgress,
  }) {
    if (duration.inSeconds < minReliableDurationSeconds) return;

    final positionRatio = position.inMilliseconds / duration.inMilliseconds;
    final pieceSize = _pieceSize;
    final offset = (_fileSizeBytes * positionRatio).round();
    final haveMap = _availableRanges.isNotEmpty && pieceSize != null;

    // Is the playhead actually on bytes the proxy can serve? The piece map
    // answers this exactly; comparing against a scalar `fileProgress` only
    // works while pieces arrive in order, and that stops being true the
    // moment we turn sequential off. After that a position well *under*
    // `fileProgress` can still sit in a gap — which is what a seek "into the
    // white part of the bar" looked like: a generic, unexplained stall.
    final inHole = haveMap
        ? isOffsetPastBuffer(
            ranges: _availableRanges,
            offset: offset,
            tolerance: pieceSize,
          )
        : isPastDownloadHead(
            positionRatio: positionRatio,
            fileProgress: fileProgress,
          );

    // …and if so, is it a seek, or has playback merely caught up with the
    // download frontier? Those need opposite handling and only the first is
    // this method's business — at the frontier, sequential download is
    // already fetching precisely the right pieces and the ordinary buffering
    // overlay explains the wait.
    final pastFrontier = isPastDownloadHead(
      positionRatio: positionRatio,
      fileProgress: fileProgress,
    );
    final seekedIntoHole =
        inHole &&
        (pastFrontier || (haveMap && hasDataAfter(_availableRanges, offset)));

    if (seekedIntoHole) {
      _seekPastHeadActive = true;
      // Only a forward seek past everything downloaded justifies dropping
      // in-order download; a gap *behind* the frontier is the very next thing
      // sequential will fetch, so leave it on.
      unawaited(
        _fetchAroundSeekTarget(offset, disableSequential: pastFrontier),
      );
      onBuffering('Fetching pieces around new position…', fileProgress);
    } else if (_seekPastHeadActive) {
      _seekPastHeadActive = false;
      _lastSeekPrefetchOffset = null;
      onBufferingResolved();
    }
  }

  /// Point qBittorrent at the seek target.
  ///
  /// Piece priority is the half that was missing. Turning sequential off only
  /// releases the picker from the head; without also saying *where to go*, it
  /// falls back to rarest-first and the bytes under the playhead arrive
  /// whenever they happen to arrive — which is why a seek into an
  /// un-downloaded region could sit on the spinner more or less indefinitely.
  ///
  /// [disableSequential] is for a forward seek past everything downloaded,
  /// where in-order download would otherwise fetch the whole intermediate
  /// region first. One-shot: turning it back on would send the picker
  /// straight back to the head.
  ///
  /// Re-issued as the target moves, throttled by [seekPrefetchResendBytes].
  /// The throttle is recorded before the first await so overlapping polls
  /// can't double-issue.
  Future<void> _fetchAroundSeekTarget(
    int offset, {
    required bool disableSequential,
  }) async {
    final previous = _lastSeekPrefetchOffset;
    if (previous != null &&
        (offset - previous).abs() < seekPrefetchResendBytes) {
      return;
    }
    _lastSeekPrefetchOffset = offset;

    if (disableSequential && !_sequentialDisabledForSeek) {
      _sequentialDisabledForSeek = true;
      await _disableSequentialForSeek();
      if (!_alive) return;
    }

    final pieceSize = _pieceSize;
    final firstPiece = _firstPiece;
    final lastPiece = _lastPiece;
    if (pieceSize == null || firstPiece == null || lastPiece == null) return;

    final ids = seekTargetPieceIds(
      offset: offset,
      firstPiece: firstPiece,
      lastPiece: lastPiece,
      pieceSize: pieceSize,
    );
    if (ids.isEmpty) return;

    try {
      final ok = await _qbt.setPiecePriority(torrentHash, ids, 7);
      AppLog.d(
        '[HealthMonitor] seek prefetch ${ok ? "set" : "failed"} — pieces '
        '${ids.first}-${ids.last} for byte $offset',
      );
    } catch (e) {
      AppLog.e('[HealthMonitor] seek prefetch failed: $e');
    }
  }

  /// Flip sequential-download off so qBittorrent can pull pieces around the
  /// seek target instead of grinding from the head. We check current state
  /// before toggling so back-to-back calls don't oscillate it.
  Future<void> _disableSequentialForSeek() async {
    try {
      final torrents = await _qbt.getTorrents(hashes: [torrentHash]);
      if (torrents.isEmpty) return;
      if (!torrents.first.sequentialDownload) {
        AppLog.d(
          '[HealthMonitor] sequential already off for $torrentHash — '
          'leaving alone',
        );
        return;
      }
      final ok = await _qbt.toggleSequentialDownload(torrentHash);
      AppLog.d(
        '[HealthMonitor] sequential download toggled off for seek '
        '(hash=$torrentHash, success=$ok)',
      );
    } catch (e) {
      AppLog.e('[HealthMonitor] failed to toggle sequential off: $e');
    }
  }

  Future<void> _recoverFromStall() async {
    _recoveryInFlight = true;
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
        await Future.delayed(const Duration(milliseconds: 300));
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
      await Future.delayed(const Duration(milliseconds: 800));
      if (!_alive) return;

      _lastObservedPosition = resumeFrom;
      _lastPositionAdvanceAt = DateTime.now();
      await _player.play();
    } catch (e) {
      AppLog.e('[HealthMonitor] Stall recovery failed: $e');
    } finally {
      _recoveryInFlight = false;
    }
  }
}
