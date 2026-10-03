import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// A media_kit [Player] with no libmpv behind it, for player tests.
///
/// A real `Player` needs the native library, which the test runner does not
/// have, so the player's lifecycle and error paths had no tests at all.
/// This records what the app asks of it, lets a test hold [open] in flight
/// with [openGate], and exposes the streams the app listens to as
/// controllers a test can drive.
class FakePlayer implements Player {
  final playing = StreamController<bool>.broadcast();
  final completed = StreamController<bool>.broadcast();
  final position = StreamController<Duration>.broadcast();
  final duration = StreamController<Duration>.broadcast();
  final volume = StreamController<double>.broadcast();
  final rate = StreamController<double>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final buffer = StreamController<Duration>.broadcast();
  final track = StreamController<Track>.broadcast();
  final tracks = StreamController<Tracks>.broadcast();
  final log = StreamController<PlayerLog>.broadcast();
  final error = StreamController<String>.broadcast();

  /// Every call the app made, by name, in order.
  final List<String> calls = [];

  /// Media handed to [open], in order.
  final List<String> opened = [];

  final List<SubtitleTrack> subtitleTracksSet = [];
  final List<AudioTrack> audioTracksSet = [];

  /// While non-null, [open] waits for it — a file that is slow to open.
  Completer<void>? openGate;

  PlayerState _state = const PlayerState();

  @override
  PlayerState get state => _state;

  set state(PlayerState value) => _state = value;

  /// Emit a log line the way mpv would.
  void emitLog(String prefix, String level, String text) =>
      log.add(PlayerLog(prefix: prefix, level: level, text: text));

  @override
  PlatformPlayer? platform;

  @override
  late final PlayerStream stream = PlayerStream(
    const Stream<Playlist>.empty(),
    playing.stream,
    completed.stream,
    position.stream,
    duration.stream,
    volume.stream,
    rate.stream,
    const Stream<double>.empty(),
    buffering.stream,
    const Stream<double>.empty(),
    buffer.stream,
    const Stream<PlaylistMode>.empty(),
    const Stream<bool>.empty(),
    const Stream<AudioParams>.empty(),
    const Stream<VideoParams>.empty(),
    const Stream<double?>.empty(),
    const Stream<AudioDevice>.empty(),
    const Stream<List<AudioDevice>>.empty(),
    track.stream,
    tracks.stream,
    const Stream<int?>.empty(),
    const Stream<int?>.empty(),
    const Stream<List<String>>.empty(),
    log.stream,
    error.stream,
  );

  // ignore: deprecated_member_use
  @override
  PlayerStream get streams => stream;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    calls.add('open');
    if (playable is Media) opened.add(playable.uri);
    final gate = openGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _state = PlayerState(volume: _state.volume);
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> playOrPause() async => calls.add('playOrPause');

  @override
  Future<void> seek(Duration duration) async => calls.add('seek $duration');

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume $volume');
    _state = _state.copyWith(volume: volume);
    this.volume.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    calls.add('setRate $rate');
    _state = _state.copyWith(rate: rate);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    calls.add('setSubtitleTrack ${track.id}');
    subtitleTracksSet.add(track);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    calls.add('setAudioTrack ${track.id}');
    audioTracksSet.add(track);
  }

  @override
  Future<void> dispose() async {
    await playing.close();
    await completed.close();
    await position.close();
    await duration.close();
    await volume.close();
    await rate.close();
    await buffering.close();
    await buffer.close();
    await track.close();
    await tracks.close();
    await log.close();
    await error.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Answer `window_manager`'s platform calls, which the player makes to set
/// the window title and to leave full screen. There is no window in a test.
void stubWindowManager() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => null,
      );
}
