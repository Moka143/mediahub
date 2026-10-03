import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/playback_failure.dart';
import '../services/app_logger.dart';
import '../services/player_service.dart';

/// Global player instance - not autoDispose to prevent issues
Player? _globalPlayer;
VideoController? _globalVideoController;

/// Provider for the media_kit Player instance.
///
/// libmpv's own log output is routed into [AppLog]. Without it, a stream
/// that opens but never renders leaves nothing to go on — the HTTP proxy
/// logs a perfectly well-formed exchange, the file on disk is valid, and
/// the only way to reason about mpv's decision is to guess from the
/// outside. mpv knows exactly why it gave up; this makes it say so.
///
/// `warn` rather than `debug`: enough to catch demuxer and stream failures
/// without flooding a long playback session (mpv at debug emits per-frame
/// chatter). Raise it here when a specific bug needs it.
///
/// The errors that end a load are also turned into [PlaybackFailure]s by
/// [PlayerService], which is what the player screen shows.
final playerProvider = Provider<Player>((ref) {
  if (_globalPlayer == null) {
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    player.stream.log.listen((log) {
      AppLog.w('[mpv:${log.prefix}/${log.level}] ${log.text.trim()}');
    });
    player.stream.error.listen((error) {
      AppLog.e('[mpv] $error');
    });
    _globalPlayer = player;
  }
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

/// Whether [id] names a track the file carries, rather than one of the two
/// selection modes media_kit lists ahead of the real tracks on every file:
/// `auto` (let mpv choose) and `no` (none).
///
/// Shown as tracks they were wrong three ways: the pickers offered "Track
/// auto" and "Track no", choosing "Track no" in the audio list silently muted
/// playback, and a file with one real audio track reported three, so the
/// Audio button — meant to hide when there is nothing to choose — never did.
bool isRealTrackId(String id) => id != 'auto' && id != 'no';

/// Subtitle tracks the file actually carries — see [isRealTrackId]. The
/// picker offers "Off" itself.
final subtitleTracksProvider = StreamProvider<List<SubtitleTrack>>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.tracks.map(
    (tracks) => [
      for (final track in tracks.subtitle)
        if (isRealTrackId(track.id)) track,
    ],
  );
});

/// Audio tracks the file actually carries — see [isRealTrackId].
final audioTracksProvider = StreamProvider<List<AudioTrack>>((ref) {
  final player = ref.watch(playerProvider);
  return player.stream.tracks.map(
    (tracks) => [
      for (final track in tracks.audio)
        if (isRealTrackId(track.id)) track,
    ],
  );
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

/// Provider for PlayerService
final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = PlayerService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});
