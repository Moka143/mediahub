import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../models/local_media_file.dart';
import '../models/playback_failure.dart';
import '../providers/player_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../utils/platform_utils.dart';
import '../utils/poll_loop.dart';
import 'app_logger.dart';

/// Whether an mpv log line means [mediaUri] cannot be played, and why.
///
/// mpv logs at `error` level for plenty it recovers from — a frame that will
/// not decode at the download edge, an external subtitle whose URL has gone
/// stale — and none of that may take over the screen. So this accepts only
/// the few messages that end a load, and only when they are about the media
/// itself rather than something loaded beside it.
PlaybackFailureKind? classifyPlayerLog(
  PlayerLog log, {
  required String mediaUri,
}) {
  if (log.level != 'error' && log.level != 'fatal') return null;
  final text = log.text;
  final lower = text.toLowerCase();
  final isUrl =
      mediaUri.startsWith('http://') || mediaUri.startsWith('https://');
  // mpv names a URL in full but may quote or escape a path, so a file is
  // recognised by its name.
  final mentionsMedia = isUrl
      ? text.contains(mediaUri)
      : text.contains(basenameOf(mediaUri));

  switch (log.prefix) {
    case 'cplayer':
      // Only ever said of the file being loaded; an unreadable subtitle is
      // "Can not open external file" instead.
      if (lower.contains('failed to recognize file format')) {
        return PlaybackFailureKind.unreadable;
      }
    case 'file':
      // "Cannot open file '<path>': No such file or directory".
      if (mentionsMedia) return PlaybackFailureKind.missingFile;
    case 'stream':
      if (mentionsMedia && lower.contains('failed to open')) {
        return isUrl
            ? PlaybackFailureKind.streamUnavailable
            : PlaybackFailureKind.missingFile;
      }
    case 'ffmpeg':
      // "tcp: Connection to tcp://127.0.0.1:53412 failed: Connection
      // refused" — the proxy is not there. Matched on host and port, since
      // a subtitle download goes through the same layer to another host.
      if (isUrl && lower.startsWith('tcp:')) {
        final authority = Uri.tryParse(mediaUri)?.authority ?? '';
        if (authority.isNotEmpty && text.contains(authority)) {
          return PlaybackFailureKind.streamUnavailable;
        }
      }
  }
  return null;
}

/// Service class for player operations
class PlayerService {
  PlayerService(this.ref);

  final Ref ref;

  /// How often playback progress is saved while a file plays.
  static const Duration progressSaveInterval = Duration(seconds: 10);

  /// How far ← / → and the skip buttons jump.
  static const Duration seekStep = Duration(seconds: 10);

  /// How much ↑ / ↓ change the volume, on mpv's 0–100 scale.
  static const double volumeStep = 10;

  late final PollLoop _progressSave = PollLoop(
    name: 'progress-save',
    onTick: _saveCurrentProgress,
  );
  LocalMediaFile? _currentFile;

  /// What mpv was handed for [_currentFile]: the file path, or the stream's
  /// URL. Null while nothing is loading or playing.
  String? _currentMediaUri;

  Completer<void>? _firstPlayCompleter;
  StreamSubscription<Duration>? _firstPlaySubscription;
  StreamSubscription<PlayerLog>? _logSubscription;
  final StreamController<PlaybackFailure> _failures =
      StreamController<PlaybackFailure>.broadcast();
  bool _failureReported = false;
  int _generation = 0;

  /// Volume to come back to on unmute: the last level above zero, however
  /// it was set. Mute used to toggle between 0 and 100, so muting at 30 and
  /// unmuting played at full volume.
  double? _lastAudibleVolume;

  Player get _player => ref.read(playerProvider);

  /// Which open (or stop) the shared player is on.
  ///
  /// [openFile] and [stop] each bump it before their first `await`, so a
  /// caller can read it straight after calling [openFile] and hold the token
  /// for the file it asked for. See [stopIfCurrent].
  int get generation => _generation;

  /// Files that could not be played, as mpv gives up on them. At most one
  /// per open, and never once the file has started playing — see [_onLog].
  Stream<PlaybackFailure> get failures => _failures.stream;

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
  ///
  /// Gives up quietly as soon as a later [openFile] or [stop] supersedes it.
  /// Closing the player while a file was still opening — the resume seek
  /// below can wait six seconds for a duration — used to let this run on
  /// and start the file with no screen in front of it.
  Future<void> openFile(
    LocalMediaFile file, {
    Duration? startPosition,
    bool isStreaming = false,
    String? streamUrl,
  }) async {
    final generation = ++_generation;
    bool superseded() => generation != _generation;

    // Nothing may be saved or reported against the outgoing file while the
    // player resets.
    _progressSave.stop();
    _currentFile = null;
    _currentMediaUri = null;

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
    if (superseded()) return;

    // Decide what URL to hand to mpv. For streaming we much prefer the local
    // HTTP proxy URL (LocalStreamingServer) over the on-disk file path:
    // qBittorrent pre-allocates the file and pads not-yet-downloaded ranges
    // with zero bytes. When mpv reads those zeros directly off disk the
    // demuxer treats them as garbage video data and freezes (`Invalid NAL
    // unit size`, paused-for-cache that never clears) — that's the "spinner
    // forever" bug. The proxy holds reads back until real bytes are written,
    // and mpv's network-stream cache handles backpressure correctly.
    final mediaUri = (isStreaming && streamUrl != null) ? streamUrl : file.path;
    _currentFile = file;
    _currentMediaUri = mediaUri;
    _failureReported = false;
    _logSubscription ??= _player.stream.log.listen(_onLog);

    // Reflect what's playing in the OS window title so the taskbar / Alt-Tab
    // switcher shows something more useful than "MediaHub".
    unawaited(_setWindowTitle(_windowTitleFor(file)));

    final platform = _player.platform;
    if (platform is NativePlayer) {
      await _tuneForSource(
        platform,
        isStreaming: isStreaming,
        viaProxy: streamUrl != null,
      );
      if (superseded()) return;
    }

    // Open the media. media_kit's open() defaults to play=true, which sets
    // mpv's `pause` property to "no" after loadfile.
    await _player.open(Media(mediaUri));
    if (superseded()) return;

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
      if (superseded()) return;
      await _player.seek(startPosition);
      if (superseded()) return;
    }

    // Start auto-save timer
    _startProgressSaveTimer();
  }

  /// mpv settings for where [openFile]'s media is coming from.
  ///
  /// They are set on the *global* mpv instance and persist across files, so
  /// every branch sets its full set — a local file opened after a stream
  /// must not inherit the stream's tuning.
  Future<void> _tuneForSource(
    NativePlayer nativePlayer, {
    required bool isStreaming,
    required bool viaProxy,
  }) async {
    if (isStreaming && viaProxy) {
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
        // Don't try to spill a multi-GB HTTP body onto disk. That fails
        // with `mkv: Failed to create file cache` and leaves playback stuck.
        await nativePlayer.setProperty('cache-on-disk', 'no');

        // Stop mpv from probing the end of the file. By default mpv reads
        // the very last region of an MKV to:
        //   • read the Cues element (seek index)
        //   • compute exact duration from the last cluster
        // For a torrent that's only 100 MB into a 2 GB file, the end is
        // not yet downloaded — qBittorrent has it as zero-padded sparse
        // bytes. Without these flags mpv blocks on the proxy waiting for
        // the tail to land, which manifests as the spinner-forever bug.
        await nativePlayer.setProperty('demuxer-mkv-probe-start-time', 'no');
        await nativePlayer.setProperty(
          'demuxer-mkv-probe-video-duration',
          'no',
        );
        // libavformat (used for MP4/WebM/etc.) has a similar tail-probe
        // pass — keep it bounded so initial open isn't dominated by tail
        // reads against an undownloaded region.
        //
        // Units: mpv takes analyzeduration in SECONDS, unlike raw ffmpeg
        // where it is microseconds. The previous value of 5000000 was the
        // microsecond figure, which mpv rejected outright —
        // "The demuxer-lavf-analyzeduration option is out of range" — so
        // this tuning silently did nothing at all. It only surfaced once
        // libmpv's own log was wired into AppLog.
        await nativePlayer.setProperty(
          'demuxer-lavf-analyzeduration',
          '5', // seconds
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
      } catch (e) {
        // Not every libmpv build exposes `cache`; the readahead tweaks above
        // are the ones that matter.
        AppLog.d('[Player] setting cache=no not supported: $e');
      }
    } else {
      // Streaming-mode properties are set on the *global* mpv instance and
      // persist across files. If a streaming session ran earlier, restore
      // sensible defaults for normal local-file playback so the next opened
      // file isn't crippled by the streaming-tuned demuxer window.
      try {
        await nativePlayer.setProperty('demuxer-max-bytes', '150000000');
        await nativePlayer.setProperty('demuxer-readahead-secs', '20');
        // force-seekable is a flag, so its off state is 'no', not 'auto'.
        // mpv rejected 'auto' at fatal level ("Invalid parameter for
        // force-seekable flag"), meaning the streaming session's
        // force-seekable=yes stayed latched on the global player for every
        // subsequent local file. ('cache' below does accept auto.)
        await nativePlayer.setProperty('force-seekable', 'no');
        await nativePlayer.setProperty('cache', 'auto');
      } catch (_) {
        // Older libmpv may reject some of these — non-fatal.
      }
    }
  }

  /// Turn the mpv log line that ends a load into a [PlaybackFailure].
  ///
  /// Only before the file has started: once it is playing, mpv's errors are
  /// about something it recovers from, and a stream that dies mid-file shows
  /// up as a stall, which the streaming health monitor already reports.
  void _onLog(PlayerLog log) {
    final mediaUri = _currentMediaUri;
    if (mediaUri == null || _failureReported || _failures.isClosed) return;
    if (_player.state.duration > Duration.zero) return;
    final kind = classifyPlayerLog(log, mediaUri: mediaUri);
    if (kind == null) return;
    _failureReported = true;
    AppLog.w('[Player] playback failed (${kind.name}): ${log.text.trim()}');
    _failures.add(
      PlaybackFailure(kind: kind, generation: _generation, detail: log.text),
    );
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
    unawaited(_firstPlaySubscription?.cancel());

    _firstPlaySubscription = _player.stream.position.listen((pos) {
      // Require a real advancement past the baseline (not just any equal/
      // smaller value emitted as mpv loads the new file).
      if (pos > baseline + const Duration(milliseconds: 50) &&
          !(_firstPlayCompleter?.isCompleted ?? true)) {
        _firstPlayCompleter!.complete();
        unawaited(_firstPlaySubscription?.cancel());
        _firstPlaySubscription = null;
      }
    });

    return _firstPlayCompleter!.future.timeout(
      timeout,
      onTimeout: () async {
        unawaited(_firstPlaySubscription?.cancel());
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
    _progressSave.start(progressSaveInterval);
  }

  /// Save current playback progress
  Future<void> _saveCurrentProgress() async {
    final file = _currentFile;
    if (file == null) return;

    final position = _player.state.position;
    final duration = _player.state.duration;

    if (duration.inSeconds <= 0) return;

    final notifier = ref.read(watchProgressProvider.notifier);
    final existing = notifier.getProgress(file.path);

    if (existing != null) {
      await notifier.updatePosition(
        file.path,
        position: position,
        duration: duration,
      );
    } else {
      await notifier.createProgress(
        filePath: file.path,
        showName: file.showName,
        showId: file.showId,
        seasonNumber: file.seasonNumber,
        episodeNumber: file.episodeNumber,
        posterPath: file.posterPath,
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

  /// Jump forward by [step].
  Future<void> seekForward([Duration step = seekStep]) async {
    await _player.seek(_player.state.position + step);
  }

  /// Jump back by [step], stopping at the start.
  Future<void> seekBackward([Duration step = seekStep]) async {
    final target = _player.state.position - step;
    await _player.seek(target.isNegative ? Duration.zero : target);
  }

  /// Set volume (0.0 - 100.0)
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 100.0);
    if (clamped > 0) _lastAudibleVolume = clamped;
    await _player.setVolume(clamped);
  }

  /// Change the volume by [delta], within 0–100.
  Future<void> adjustVolume(double delta) =>
      setVolume(_player.state.volume + delta);

  /// Mute, or unmute back to the level playback had before.
  Future<void> toggleMute() async {
    final current = _player.state.volume;
    if (current > 0) {
      _lastAudibleVolume = current;
      await _player.setVolume(0);
    } else {
      await _player.setVolume(_lastAudibleVolume ?? 100);
    }
  }

  /// Set playback speed/rate
  Future<void> setPlaybackRate(double rate) async {
    await _player.setRate(rate.clamp(0.25, 4.0));
  }

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
    _generation++;
    _progressSave.stop();
    _currentMediaUri = null;
    unawaited(_firstPlaySubscription?.cancel());
    _firstPlaySubscription = null;
    if (!(_firstPlayCompleter?.isCompleted ?? true)) {
      _firstPlayCompleter?.complete();
    }
    _firstPlayCompleter = null;
    try {
      await _saveCurrentProgress();
      await _player.stop();
      _currentFile = null;
      unawaited(_setWindowTitle(AppConstants.appName));
    } catch (e) {
      // Ignore errors during stop - provider may be disposed
    }
  }

  /// Stop playback, unless the player has been opened or stopped since
  /// [generation] — then what is playing belongs to someone else.
  ///
  /// For screens that are going away. A player screen replaced by the next
  /// episode's is disposed *after* the new one has opened its file, so a
  /// plain [stop] there would stop the next episode.
  Future<void> stopIfCurrent(int generation) async {
    if (generation != _generation) return;
    await stop();
  }

  /// A window title is cosmetic; failing to set one must not surface.
  Future<void> _setWindowTitle(String title) async {
    try {
      await windowManager.setTitle(title);
    } catch (e) {
      AppLog.d('[Player] could not set the window title: $e');
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
      final code = Formatters.episodeCode(
        file.seasonNumber!,
        file.episodeNumber!,
      );
      primary = '${file.showName} — $code';
    } else if (file.showName != null) {
      primary = file.showName!;
    } else {
      primary = file.fileName;
    }
    return '$primary · ${AppConstants.appName}';
  }

  /// Dispose resources
  void dispose() {
    _progressSave.dispose();
    unawaited(_firstPlaySubscription?.cancel());
    unawaited(_logSubscription?.cancel());
    unawaited(_failures.close());
  }
}
