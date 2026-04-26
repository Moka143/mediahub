import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../models/local_media_file.dart';
import '../utils/constants.dart';
import 'watch_progress_provider.dart';

/// Notifier for current playing file
class CurrentPlayingFileNotifier extends Notifier<LocalMediaFile?> {
  @override
  LocalMediaFile? build() => null;

  void set(LocalMediaFile? file) => state = file;
}

/// Current playing file provider
final currentPlayingFileProvider =
    NotifierProvider<CurrentPlayingFileNotifier, LocalMediaFile?>(
      CurrentPlayingFileNotifier.new,
    );

/// Global player instance - not autoDispose to prevent issues
Player? _globalPlayer;
VideoController? _globalVideoController;

/// Provider for the media_kit Player instance
final playerProvider = Provider<Player>((ref) {
  _globalPlayer ??= Player();
  return _globalPlayer!;
});

/// Provider for video controller
final videoControllerProvider = Provider<VideoController>((ref) {
  final player = ref.watch(playerProvider);
  _globalVideoController ??= VideoController(player);
  return _globalVideoController!;
});

/// Provider for current playback position
final playbackPositionProvider = StreamProvider<Duration>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.position;
});

/// Provider for total duration
final playbackDurationProvider = StreamProvider<Duration>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.duration;
});

/// Provider for playing state
final isPlayingProvider = StreamProvider<bool>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.playing;
});

/// Provider for buffering state
final isBufferingProvider = StreamProvider<bool>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.buffering;
});

/// Provider for buffered position — how far ahead the player has cached.
/// Used to render the "buffered" region on the seek bar.
final playbackBufferProvider = StreamProvider<Duration>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.buffer;
});

/// Provider for volume
final volumeProvider = StreamProvider<double>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.volume;
});

/// Provider for playback rate/speed
final playbackRateProvider = StreamProvider<double>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.rate;
});

/// Provider for available subtitle tracks
final subtitleTracksProvider = StreamProvider<List<SubtitleTrack>>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.tracks.map((tracks) => tracks.subtitle);
});

/// Provider for available audio tracks
final audioTracksProvider = StreamProvider<List<AudioTrack>>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.tracks.map((tracks) => tracks.audio);
});

/// Provider for current subtitle track
final currentSubtitleTrackProvider = StreamProvider<SubtitleTrack>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.track.map((track) => track.subtitle);
});

/// Provider for current audio track
final currentAudioTrackProvider = StreamProvider<AudioTrack>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.track.map((track) => track.audio);
});

/// Provider for playback completed
final playbackCompletedProvider = StreamProvider<bool>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.completed;
});

/// Service class for player operations
class PlayerService {
  final Ref ref;
  Timer? _progressSaveTimer;
  LocalMediaFile? _currentFile;
  Completer<void>? _firstPlayCompleter;
  StreamSubscription<Duration>? _firstPlaySubscription;

  PlayerService(this.ref);

  Player get _player => ref.read(playerProvider);

  /// Open and play a video file.
  ///
  /// Set [isStreaming] to true when the file is being downloaded in real
  /// time. In that case the caller should normally also provide [streamUrl]
  /// — an `http://127.0.0.1:.../...` URL served by [LocalStreamingServer]
  /// that proxies the partial file with proper byte-range backpressure.
  /// mpv reads from the HTTP URL instead of the on-disk file so it doesn't
  /// choke on the zero-padded sparse regions qBittorrent leaves for un-
  /// downloaded bytes; mpv's network cache layer then handles the wait
  /// gracefully (paused-for-cache that actually clears when bytes arrive).
  Future<void> openFile(
    LocalMediaFile file, {
    Duration? startPosition,
    bool isStreaming = false,
    String? streamUrl,
  }) async {
    // Hard-reset the global player before loading a new file. Without this
    // the previous session's `playing=true, position>0` leaks into the new
    // session: the streaming-mode buffering UI uses player state to decide
    // when initial loading is over, and stale state causes it to declare
    // "playing" before the new file has even been opened — leaving the
    // spinner stuck on top of a mpv instance that's still actually loading.
    try {
      await _player.stop();
    } catch (_) {
      // No media loaded yet — non-fatal.
    }

    _currentFile = file;
    ref.read(currentPlayingFileProvider.notifier).set(file);

    // Reflect what's playing in the OS window title so the taskbar / Alt-Tab
    // switcher shows something more useful than "MediaHub".
    unawaited(windowManager.setTitle(_windowTitleFor(file)));

    // Decide what URL to hand to mpv. For streaming we much prefer the local
    // HTTP proxy URL (LocalStreamingServer) over the on-disk file path:
    // qBittorrent pre-allocates the file and pads not-yet-downloaded ranges
    // with zero bytes. When mpv reads those zeros directly off disk the
    // demuxer treats them as garbage video data and freezes (`Invalid NAL
    // unit size`, paused-for-cache that never clears) — that's the "spinner
    // forever" bug. The proxy holds reads back until real bytes are written,
    // and mpv's network-stream cache handles backpressure correctly.
    final mediaUri = (isStreaming && streamUrl != null) ? streamUrl : file.path;
    final nativePlayer = _player.platform as NativePlayer;

    if (isStreaming && streamUrl != null) {
      // mpv is now talking to a localhost HTTP server. Let mpv's network
      // cache do its job: it'll pause-for-cache while the proxy is waiting
      // on bytes from qBittorrent, and resume the moment data flows again.
      try {
        await nativePlayer.setProperty('cache', 'yes');
        await nativePlayer.setProperty('cache-secs', '30');
        // Don't wait on initial cache fill — start playback as soon as
        // mpv has decoded the first frame. Default is already 'no' but
        // we set it explicitly because some libmpv builds flip it.
        await nativePlayer.setProperty('cache-pause-initial', 'no');
        // After a cache underrun, resume playback after only 1 s of
        // buffering instead of the 4 s default. The proxy serves bytes
        // as soon as qBittorrent writes them, so 4 s of waiting is
        // overkill and just makes streaming feel laggy.
        await nativePlayer.setProperty('cache-pause-wait', '1');
        await nativePlayer.setProperty('demuxer-max-bytes', '50000000');
        await nativePlayer.setProperty('demuxer-readahead-secs', '15');
        // The proxy can be slow to respond when we're at the download edge
        // — give libavformat time before it gives up.
        await nativePlayer.setProperty('network-timeout', '60');

        // Stop mpv from probing the end of the file. By default mpv reads
        // the very last region of an MKV to:
        //   • read the Cues element (seek index)
        //   • compute exact duration from the last cluster
        // For a torrent that's only 100 MB into a 2 GB file, the end is
        // not yet downloaded — qBittorrent has it as zero-padded sparse
        // bytes. Without these flags mpv blocks on the proxy waiting for
        // the tail to land, which manifests as the spinner-forever bug.
        await nativePlayer.setProperty(
          'demuxer-mkv-probe-start-time',
          'no',
        );
        await nativePlayer.setProperty(
          'demuxer-mkv-probe-video-duration',
          'no',
        );
        // libavformat (used for MP4/WebM/etc.) has a similar tail-probe
        // pass — keep it bounded so initial open isn't dominated by tail
        // reads against an undownloaded region. Note: analyzeduration is
        // in *microseconds*. Setting it to 1 (the previous value) meant
        // 1 µs of analysis, which is far too short for libavformat to
        // identify the codec and stream layout — mpv would silently fail
        // to open the file. 5 seconds is a sane minimum.
        await nativePlayer.setProperty(
          'demuxer-lavf-analyzeduration',
          '5000000', // 5 seconds (microseconds)
        );
        await nativePlayer.setProperty(
          'demuxer-lavf-probesize',
          '8388608', // 8 MB
        );
      } catch (_) {
        // Older libmpv may reject some — non-fatal.
      }
    } else if (isStreaming) {
      // Fallback: streaming requested but no proxy URL available. Use the
      // older direct-disk tweaks; spinner-forever bug may resurface, but at
      // least we don't crash. Logged in StreamingService.
      await nativePlayer.setProperty('demuxer-max-bytes', '50000000');
      await nativePlayer.setProperty('demuxer-readahead-secs', '8');
      await nativePlayer.setProperty('force-seekable', 'yes');
      try {
        await nativePlayer.setProperty('cache', 'no');
      } catch (_) {}
    } else {
      // Streaming-mode properties are set on the *global* mpv instance and
      // persist across files. If a streaming session ran earlier, restore
      // sensible defaults for normal local-file playback so the next opened
      // file isn't crippled by the streaming-tuned demuxer window.
      try {
        await nativePlayer.setProperty('demuxer-max-bytes', '150000000');
        await nativePlayer.setProperty('demuxer-readahead-secs', '20');
        await nativePlayer.setProperty('force-seekable', 'auto');
        await nativePlayer.setProperty('cache', 'auto');
      } catch (_) {
        // Older libmpv may reject some of these — non-fatal.
      }
    }

    // Open the media. media_kit's open() defaults to play=true, which sets
    // mpv's `pause` property to "no" after loadfile.
    await _player.open(Media(mediaUri));

    // Seek to start position if provided — wait for a valid duration rather
    // than a blind 500 ms delay, which was too short on slow storage.
    if (startPosition != null && startPosition.inSeconds > 0) {
      try {
        await _player.stream.duration
            .firstWhere((d) => d.inSeconds > 0)
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        // Timed out waiting for duration — seek anyway, best-effort
      }
      await _player.seek(startPosition);
    }

    // Start auto-save timer
    _startProgressSaveTimer();
  }

  /// Returns a [Future] that completes when mpv is *actually* playing —
  /// i.e. the position has moved, not just the `pause` flag flipped to no.
  ///
  /// Why position-based? media_kit emits `playing: true` as soon as it sets
  /// mpv's `pause` property to `no` inside `Player.open()`, even before mpv
  /// has demuxed the first frame. For partially-downloaded torrent files
  /// mpv can sit in `paused-for-cache=true` indefinitely while still
  /// reporting `playing: true` to us. Watching position advance is the only
  /// honest signal that frames are being delivered.
  ///
  /// On timeout, runs a real recovery (forward-probe seek + back) which
  /// forces mpv to flush its demuxer state. A bare `play()` won't do it —
  /// `play()` just clears the *user* pause, not `paused-for-cache`.
  Future<void> waitForFirstPlay({
    Duration timeout = const Duration(seconds: 7),
  }) async {
    // Baseline = position at the moment the caller starts waiting.
    // openFile() now hard-stops the player before loading, so this is
    // typically Duration.zero — but we capture explicitly in case the caller
    // is invoking us mid-playback (e.g. after a resume seek).
    //
    // Previously this method:
    //   • short-circuited when the *global* player still reported
    //     `playing && position > 0` from a previous session — returning
    //     before the new file was even loaded; and
    //   • used "first emitted position event" as the baseline. If the
    //     subscription was set up before the new file's open() fully
    //     applied, the first event could be the previous file's stale
    //     position (e.g. 1500s); the new file then resets to 0 and never
    //     "advances past 1500s", so the completer never fired and the
    //     streaming spinner was stuck waiting on a 7s timeout every time.
    final baseline = _player.state.position;

    _firstPlayCompleter = Completer<void>();
    _firstPlaySubscription?.cancel();

    _firstPlaySubscription = _player.stream.position.listen((pos) {
      // Require a real advancement past the baseline (not just any equal/
      // smaller value emitted as mpv loads the new file).
      if (pos > baseline + const Duration(milliseconds: 50) &&
          !(_firstPlayCompleter?.isCompleted ?? true)) {
        _firstPlayCompleter!.complete();
        _firstPlaySubscription?.cancel();
        _firstPlaySubscription = null;
      }
    });

    return _firstPlayCompleter!.future.timeout(
      timeout,
      onTimeout: () async {
        _firstPlaySubscription?.cancel();
        _firstPlaySubscription = null;
        // A forward-then-back seek forces mpv to flush its demuxer cache,
        // which is what actually clears `paused-for-cache` when mpv has
        // gotten stuck reading sparse zero data. Calling `play()` alone
        // only flips the user-pause flag and doesn't help.
        try {
          final pos = _player.state.position;
          await _player.pause();
          await _player.seek(pos + const Duration(seconds: 1));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await _player.seek(pos);
          await _player.play();
        } catch (_) {
          // Worst case fall back to a plain play() — better than nothing.
          await _player.play();
        }
      },
    );
  }

  /// Start saving progress periodically
  void _startProgressSaveTimer() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _saveCurrentProgress();
    });
  }

  /// Save current playback progress
  Future<void> _saveCurrentProgress() async {
    if (_currentFile == null) return;

    final position = _player.state.position;
    final duration = _player.state.duration;

    if (duration.inSeconds <= 0) return;

    final notifier = ref.read(watchProgressProvider.notifier);
    final existing = notifier.getProgress(_currentFile!.path);

    if (existing != null) {
      await notifier.updatePosition(
        _currentFile!.path,
        position: position,
        duration: duration,
      );
    } else {
      await notifier.createProgress(
        filePath: _currentFile!.path,
        showName: _currentFile!.showName,
        showId: _currentFile!.showId,
        seasonNumber: _currentFile!.seasonNumber,
        episodeNumber: _currentFile!.episodeNumber,
        posterPath: _currentFile!.posterPath,
        position: position,
        duration: duration,
      );
    }
  }

  /// Play
  Future<void> play() async {
    await _player.play();
  }

  /// Pause
  Future<void> pause() async {
    await _player.pause();
    await _saveCurrentProgress();
  }

  /// Play or pause
  Future<void> playOrPause() async {
    await _player.playOrPause();
  }

  /// Seek to position
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  /// Seek forward by seconds
  Future<void> seekForward({int seconds = 10}) async {
    final current = _player.state.position;
    final target = current + Duration(seconds: seconds);
    await _player.seek(target);
  }

  /// Seek backward by seconds
  Future<void> seekBackward({int seconds = 10}) async {
    final current = _player.state.position;
    final target = current - Duration(seconds: seconds);
    await _player.seek(target.isNegative ? Duration.zero : target);
  }

  /// Set volume (0.0 - 100.0)
  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0.0, 100.0));
  }

  /// Toggle mute
  Future<void> toggleMute() async {
    final currentVolume = _player.state.volume;
    if (currentVolume > 0) {
      await _player.setVolume(0);
    } else {
      await _player.setVolume(100);
    }
  }

  /// Set playback speed/rate
  Future<void> setPlaybackRate(double rate) async {
    await _player.setRate(rate.clamp(0.25, 4.0));
  }

  /// Get current playback rate
  double get currentPlaybackRate => _player.state.rate;

  /// Set subtitle track
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    await _player.setSubtitleTrack(track);
  }

  /// Set audio track
  Future<void> setAudioTrack(AudioTrack track) async {
    await _player.setAudioTrack(track);
  }

  /// Load external subtitle file
  Future<void> loadExternalSubtitle(String path) async {
    await _player.setSubtitleTrack(SubtitleTrack.uri(path));
  }

  /// Stop playback and save progress
  Future<void> stop() async {
    _progressSaveTimer?.cancel();
    _firstPlaySubscription?.cancel();
    _firstPlaySubscription = null;
    if (!(_firstPlayCompleter?.isCompleted ?? true)) {
      _firstPlayCompleter?.complete();
    }
    _firstPlayCompleter = null;
    try {
      await _saveCurrentProgress();
      await _player.stop();
      _currentFile = null;
      ref.read(currentPlayingFileProvider.notifier).set(null);
      unawaited(windowManager.setTitle(AppConstants.appName));
    } catch (e) {
      // Ignore errors during stop - provider may be disposed
    }
  }

  /// Build a friendly window-title string for a media file.
  ///
  /// Uses `Show Name — S01E02` for episodes, the bare show name for shows
  /// without episode info, and the file name as the fallback. Always suffixed
  /// with the app name so users know which window is MediaHub in the taskbar.
  String _windowTitleFor(LocalMediaFile file) {
    String primary;
    if (file.showName != null &&
        file.seasonNumber != null &&
        file.episodeNumber != null) {
      final s = file.seasonNumber!.toString().padLeft(2, '0');
      final e = file.episodeNumber!.toString().padLeft(2, '0');
      primary = '${file.showName} — S${s}E$e';
    } else if (file.showName != null) {
      primary = file.showName!;
    } else {
      primary = file.fileName;
    }
    return '$primary · ${AppConstants.appName}';
  }

  /// Dispose resources
  void dispose() {
    _progressSaveTimer?.cancel();
    _firstPlaySubscription?.cancel();
  }
}

/// Provider for PlayerService
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});
