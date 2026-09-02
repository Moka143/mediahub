import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/connection_provider.dart';
import '../providers/player_provider.dart';
import '../services/playback_health_monitor.dart';
import '../widgets/streaming_status_indicator.dart';

/// Everything the player does *because the file is still downloading*:
/// the download-edge health monitor, the debounce that keeps mpv's buffering
/// signal from strobing the spinner, and the status chip both of them drive.
///
/// Split out of `video_player_screen.dart` as step 2 of
/// docs/player-screen-decomposition.md. The heavy lifting was already
/// self-contained in [PlaybackHealthMonitor], which owns its own timer and
/// subscription and has its own tests; what lived on the screen was the
/// wiring, four tuning constants and eleven fields that only these three
/// methods touched.
///
/// Nothing here runs unless the screen is streaming — [startPlaybackHealthMonitor]
/// returns immediately without a torrent hash, since without one only the
/// stall detector would be useful and it would fire on ordinary user pauses.
///
/// [dismissStreamingStatus] also satisfies the abstract member of
/// [PlayerNextEpisodeController]: the prefetch flow clears the current
/// episode's chip before handing over. That resolves by mixin application
/// order, so this mixin must be applied after it.
mixin PlayerStreamingHealth<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  // ── What the host screen must provide ──────────────────────────────────

  /// qBittorrent info-hash backing this playback, or null when the file is
  /// complete on disk.
  String? get streamingTorrentHash;

  /// Index of the playing file within that torrent.
  int? get streamingFileIndex;

  /// The loopback proxy URL mpv is reading through, when there is one.
  String? get streamingProxyUrl;

  // ── Owned state ────────────────────────────────────────────────────────

  // Streaming status indicator (current-episode health monitor only —
  // next-episode prefetch lives in [nextPrefetch] beside the CW pill).
  StreamingStatus? streamingStatus;

  String streamingMessage = '';

  String? streamingEpisodeCode;

  double? streamingProgress;

  // Debounced buffering state for streaming mode —
  // mpv's buffering signal flickers rapidly when reading at the edge
  // of partially-downloaded data, so we smooth it out.
  bool streamBuffering = false;

  bool streamBufferingGrace = false; // suppress indicator right after open

  Timer? _bufferingDebounceTimer;

  StreamSubscription<bool>? _bufferingSubscription;

  /// Watches the player position vs. the torrent's download edge and
  /// pauses/resumes/recovers accordingly. Only created while streaming; owns
  /// all of its own timers and subscriptions. See [PlaybackHealthMonitor].
  PlaybackHealthMonitor? _healthMonitor;

  // Latest 0.0–1.0 download progress for the streaming target file.
  // Drives the buffering overlay's percentage, and the seek-bar's buffered
  // track when no piece map is available. Fed by the monitor's
  // onDownloadedRatio callback; read by build().
  double? streamingDownloadedRatio;

  // Where those bytes actually are, from the torrent's piece map. Preferred
  // over the scalar above for the seek-bar track: once the user seeks we turn
  // sequential download off, after which "60% downloaded" no longer means
  // "the first 60% is playable". Empty until the first piece-map poll lands,
  // or permanently if qBittorrent won't give us one.
  List<BufferedSpan> bufferedSpans = const [];

  static const _bufferingShowDelay = Duration(milliseconds: 400);

  static const _bufferingHideDelay = Duration(seconds: 1);

  // Keep this in sync with PlayerService.waitForFirstPlay's default — both
  // values gate the same "still loading?" deadline.
  static const _firstPlayTimeout = Duration(seconds: 7);

  static const _postPlayGrace = Duration(milliseconds: 500);

  /// Build and start the playback health monitor for this streaming session.
  ///
  /// Called from both `_initializePlayer` and `_handleResume`; safe to call
  /// twice because the previous instance is disposed first and the monitor
  /// resets all of its counters in `start()`.
  void startPlaybackHealthMonitor() {
    final hash = streamingTorrentHash;
    if (hash == null) {
      // Without a hash we can't query torrent state — only the stall detector
      // would be useful, and it'd fire on legitimate user pauses too. Skip.
      return;
    }

    _healthMonitor?.dispose();
    _healthMonitor = PlaybackHealthMonitor(
      player: ref.read(playerProvider),
      qbt: ref.read(qbApiServiceProvider),
      torrentHash: hash,
      fileIndex: streamingFileIndex,
      usingProxy: streamingProxyUrl != null,
      isActive: () => mounted,
      onDownloadedRatio: (ratio) {
        if (!mounted) return;
        if (streamingDownloadedRatio == null ||
            (ratio - streamingDownloadedRatio!).abs() > 0.001) {
          setState(() => streamingDownloadedRatio = ratio);
        }
      },
      onBufferedSpans: (spans) {
        if (!mounted) return;
        if (!listEquals(spans, bufferedSpans)) {
          setState(() => bufferedSpans = spans);
        }
      },
      onBuffering: (message, progress) => showStreamingStatus(
        status: StreamingStatus.buffering,
        message: message,
        progress: progress,
      ),
      onBufferingResolved: dismissStreamingStatus,
    )..start();
  }

  /// Smooth out mpv's rapid buffering signal during streaming.
  ///
  /// • Suppress the indicator until mpv actually starts playing (dynamic grace
  ///   period), plus 1 s stabilisation — avoids a second "loading" right after
  ///   the streaming overlay just disappeared.
  /// • Show the indicator only after buffering has been true for 400 ms
  ///   (ignores sub-second micro-stalls).
  /// • Once shown, keep it visible for at least 1 s after buffering clears
  ///   (prevents rapid on/off flicker).
  void setupStreamingBufferingDebounce() {
    // Restart-safe: _handleResume calls this a second time after the resume
    // prompt, and a second listener on the same stream would double every
    // buffering transition.
    _bufferingSubscription?.cancel();

    // Grace period — suppress indicator until mpv actually starts playing,
    // rather than using a fixed timer that may expire too early for large files.
    streamBufferingGrace = true;
    final playerService = ref.read(playerServiceProvider);
    playerService.waitForFirstPlay(timeout: _firstPlayTimeout).then((_) {
      // Extra stabilisation after first play to absorb initial decode stalls.
      Future.delayed(_postPlayGrace, () {
        if (mounted) setState(() => streamBufferingGrace = false);
      });
    });

    final player = ref.read(playerProvider);
    _bufferingSubscription = player.stream.buffering.listen((isBuffering) {
      if (!mounted) return;
      // Always (re)schedule a transition based on the latest signal. Without
      // this, a sequence of buffering=true→false→true→false at the download
      // edge could leave us with `streamBuffering=true` permanently: the
      // hide-timer scheduled on the false event gets cancelled by the next
      // true event but no fresh hide-timer is set when buffering eventually
      // settles to false (because `streamBuffering` is already true so the
      // first branch's guard `&& !streamBuffering` was false).
      _bufferingDebounceTimer?.cancel();

      if (isBuffering) {
        if (streamBuffering) return;
        _bufferingDebounceTimer = Timer(_bufferingShowDelay, () {
          if (mounted) setState(() => streamBuffering = true);
        });
      } else {
        if (!streamBuffering) return;
        _bufferingDebounceTimer = Timer(_bufferingHideDelay, () {
          if (mounted) setState(() => streamBuffering = false);
        });
      }
    });
  }

  void dismissStreamingStatus() {
    if (mounted) {
      setState(() {
        streamingStatus = null;
        streamingMessage = '';
        streamingEpisodeCode = null;
        streamingProgress = null;
      });
    }
  }

  /// Compose the chip text shown under the buffering spinner during
  /// streaming. Falls back to a plain "Buffering…" when we don't have
  /// the download ratio yet (very first frames after open).
  String bufferingLabel(double? downloadedRatio) {
    if (downloadedRatio == null) return 'Buffering…';
    final pct = (downloadedRatio * 100).clamp(0, 100).toStringAsFixed(1);
    return 'Buffering — $pct% downloaded';
  }

  void showStreamingStatus({
    required StreamingStatus status,
    required String message,
    String? episodeCode,
    double? progress,
  }) {
    if (mounted) {
      setState(() {
        streamingStatus = status;
        streamingMessage = message;
        streamingEpisodeCode = episodeCode;
        streamingProgress = progress;
      });
    }
  }

  /// Stop the monitor and the debounce. Called from the screen's `dispose()`
  /// in the position these three teardowns already occupied.
  void disposeStreamingHealth() {
    _bufferingDebounceTimer?.cancel();
    _bufferingSubscription?.cancel();
    // Synchronous and ref-free — the monitor owns its own timer and stream
    // subscription and needs no providers to shut down.
    _healthMonitor?.dispose();
  }
}
