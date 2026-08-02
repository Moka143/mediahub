import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'app_logger.dart';
import 'qbittorrent_api_service.dart';

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
    required QBittorrentApiService qbt,
    required this.torrentHash,
    required this.fileIndex,
    required this.usingProxy,
    required this.isActive,
    required this.onDownloadedRatio,
    required this.onBuffering,
    required this.onBufferingResolved,
  }) : _player = player,
       _qbt = qbt;

  final Player _player;
  final QBittorrentApiService _qbt;

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
  /// seek-bar's buffered track.
  final void Function(double ratio) onDownloadedRatio;

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
  static const double pastHeadSlack = 0.01;

  /// mpv occasionally reports a near-zero duration during initial open,
  /// before the demuxer settles. Ratio maths is meaningless until then.
  static const int minReliableDurationSeconds = 30;

  /// Treat the file as complete at this point — nothing useful left to pause
  /// for.
  static const double completeEnough = 0.995;

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------

  Timer? _timer;
  StreamSubscription<Duration>? _positionSub;

  Duration _lastObservedPosition = Duration.zero;
  DateTime _lastPositionAdvanceAt = DateTime.now();
  DateTime _lastRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _autoBufferPaused = false;
  bool _recoveryInFlight = false;
  bool _checkInFlight = false;
  bool _disposed = false;

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

    _timer?.cancel();
    _positionSub?.cancel();

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

    _timer = Timer.periodic(pollInterval, (_) => _runCheck());
    // Fire once immediately so the seek-bar's buffered region populates
    // without waiting a full poll interval.
    _runCheck();
  }

  /// Stop monitoring. Synchronous and dependency-free so the player screen can
  /// call it from `dispose()`, where providers may already be torn down.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _positionSub?.cancel();
    _positionSub = null;
  }

  bool get _alive => !_disposed && isActive();

  // ---------------------------------------------------------------------
  // Poll
  // ---------------------------------------------------------------------

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

    // 2) Edge tracking.
    try {
      final files = await _qbt.getTorrentFiles(torrentHash);
      final idx = fileIndex;
      if (idx == null || idx < 0 || idx >= files.length) return;
      if (!_alive) return;

      final file = files[idx];
      final fileSize = file.size;
      final fileProgress = file.progress;
      if (fileSize <= 0) return;

      onDownloadedRatio(fileProgress);

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

    final pastHead = isPastDownloadHead(
      positionRatio: position.inMilliseconds / duration.inMilliseconds,
      fileProgress: fileProgress,
    );

    if (pastHead) {
      _seekPastHeadActive = true;
      if (!_sequentialDisabledForSeek) {
        _sequentialDisabledForSeek = true;
        unawaited(_disableSequentialForSeek());
      }
      onBuffering('Fetching pieces around new position…', fileProgress);
    } else if (_seekPastHeadActive) {
      _seekPastHeadActive = false;
      onBufferingResolved();
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
