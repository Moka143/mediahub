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
  StreamSubscription<bool>? _firstPlaySubscription;

  PlayerService(this.ref);

  Player get _player => ref.read(playerProvider);

  /// Open and play a video file.
  /// Set [isStreaming] to true when opening a partially downloaded file
  /// to configure mpv's cache for tolerating incomplete data.
  Future<void> openFile(
    LocalMediaFile file, {
    Duration? startPosition,
    bool isStreaming = false,
  }) async {
    _currentFile = file;
    ref.read(currentPlayingFileProvider.notifier).set(file);

    // Reflect what's playing in the OS window title so the taskbar / Alt-Tab
    // switcher shows something more useful than "MediaHub".
    unawaited(windowManager.setTitle(_windowTitleFor(file)));

    // For streaming (partially downloaded files), enable mpv cache so it
    // can pause/resume when it reaches the edge of available data.
    if (isStreaming) {
      final nativePlayer = _player.platform as NativePlayer;
      await nativePlayer.setProperty('cache', 'yes');
      await nativePlayer.setProperty('cache-pause', 'yes');
      // Resume after 1 s of cached data. With the improved initial buffer
      // (contiguous pieces verified) this is a safe threshold that avoids
      // micro-stalls without requiring aggressive download speed.
      await nativePlayer.setProperty('cache-pause-wait', '1');
      // Start playback immediately — don't wait for initial cache fill
      await nativePlayer.setProperty('cache-pause-initial', 'no');
      await nativePlayer.setProperty(
        'demuxer-max-bytes',
        '150000000',
      ); // 150 MB
      // Moderate read-ahead so the demuxer stays within downloaded data
      await nativePlayer.setProperty('demuxer-readahead-secs', '30');
    }

    // Open the media file
    await _player.open(Media(file.path));

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

  /// Returns a [Future] that completes when mpv first reports playing.
  ///
  /// If playback doesn't start within [timeout], forces a play() call as
  /// recovery (mpv may be stuck in cache-pause).  Returns immediately if the
  /// player is already playing.
  Future<void> waitForFirstPlay({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_player.state.playing) return;

    _firstPlayCompleter = Completer<void>();
    _firstPlaySubscription?.cancel();
    _firstPlaySubscription = _player.stream.playing.listen((isPlaying) {
      if (isPlaying && !(_firstPlayCompleter?.isCompleted ?? true)) {
        _firstPlayCompleter!.complete();
        _firstPlaySubscription?.cancel();
        _firstPlaySubscription = null;
      }
    });

    return _firstPlayCompleter!.future.timeout(
      timeout,
      onTimeout: () {
        _firstPlaySubscription?.cancel();
        _firstPlaySubscription = null;
        // Recovery: force play if mpv got stuck in cache-pause
        _player.play();
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
