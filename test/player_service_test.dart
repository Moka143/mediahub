import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/playback_failure.dart';
import 'package:mediahub/providers/player_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/services/player_service.dart';
import 'package:mediahub/widgets/player/volume_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_test_fakes.dart';

LocalMediaFile _file(String name) => LocalMediaFile(
  path: '/library/$name',
  fileName: name,
  sizeBytes: 4 << 30,
  modifiedDate: DateTime(2026),
  extension: 'mkv',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  stubWindowManager();

  late FakePlayer player;
  late ProviderContainer container;
  late PlayerService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    player = FakePlayer();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        playerProvider.overrideWithValue(player),
      ],
    );
    service = container.read(playerServiceProvider);
  });

  tearDown(() async {
    container.dispose();
    await player.dispose();
  });

  group('mute', () {
    // Mute used to toggle between 0 and 100: muted at 30, unmuted at full
    // volume.
    test('unmute restores the level it muted at', () async {
      await service.setVolume(30);
      await service.toggleMute();
      expect(player.state.volume, 0);
      await service.toggleMute();
      expect(player.state.volume, 30);
    });

    test('a volume never touched comes back to where it was', () async {
      await service.toggleMute();
      expect(player.state.volume, 0);
      await service.toggleMute();
      expect(player.state.volume, 100);
    });

    test(
      'dragged to zero, unmute brings back the last audible level',
      () async {
        await service.setVolume(40);
        await service.setVolume(0);
        await service.toggleMute();
        expect(player.state.volume, 40);
      },
    );

    test('the arrow keys step within 0–100', () async {
      await service.setVolume(95);
      await service.adjustVolume(PlayerService.volumeStep);
      expect(player.state.volume, 100);
      await service.setVolume(5);
      await service.adjustVolume(-PlayerService.volumeStep);
      expect(player.state.volume, 0);
      // …and M after stepping down to silence returns to the last level.
      await service.toggleMute();
      expect(player.state.volume, 5);
    });
  });

  testWidgets('the volume button mutes and unmutes, not sets 0 or 100', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: VolumeControl(
              volume: 30,
              onVolumeChanged: (v) => events.add('set $v'),
              onToggleMute: () => events.add('toggleMute'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Mute (M)'));
    expect(events, ['toggleMute']);
  });

  group('who may stop the shared player', () {
    test('a screen stops what it opened', () async {
      await service.openFile(_file('a.mkv'));
      final mine = service.generation;
      player.calls.clear();

      await service.stopIfCurrent(mine);
      expect(player.calls, contains('stop'));
    });

    test('a screen being replaced does not stop the next file', () async {
      // The next-episode hand-off: the outgoing screen is disposed after the
      // incoming one has opened its file.
      await service.openFile(_file('S01E01.mkv'));
      final outgoing = service.generation;
      await service.openFile(_file('S01E02.mkv'));
      player.calls.clear();

      await service.stopIfCurrent(outgoing);
      expect(player.calls, isNot(contains('stop')));
    });

    test('closing while a file is still opening leaves it stopped', () async {
      // `openFile` can wait seconds for a duration before a resume seek.
      // Closing in that window used to let it run on — seek, start saving
      // progress, play — with no screen in front of it.
      player.openGate = Completer<void>();
      final opening = service.openFile(
        _file('long.mkv'),
        startPosition: const Duration(minutes: 30),
      );
      final generation = service.generation;
      await pumpEventQueue();
      expect(player.opened, ['/library/long.mkv']);

      await service.stopIfCurrent(generation);
      player.calls.clear();
      player.openGate!.complete();
      await opening;

      expect(
        player.calls,
        isEmpty,
        reason: 'a superseded open must not seek or play on',
      );
      // The token is spent: a second stop from the same screen — its
      // dispose, after the back button — finds nothing of its own to stop.
      await service.stopIfCurrent(generation);
      expect(player.calls, isEmpty);
    });
  });

  group('playback failures', () {
    Future<List<PlaybackFailure>> collect(Future<void> Function() act) async {
      final failures = <PlaybackFailure>[];
      final sub = service.failures.listen(failures.add);
      await act();
      await pumpEventQueue();
      await sub.cancel();
      return failures;
    }

    test('an unreadable file is reported once, for its open', () async {
      final failures = await collect(() async {
        await service.openFile(_file('zeros.mkv'));
        player.emitLog('cplayer', 'error', 'Failed to recognize file format.');
        player.emitLog('cplayer', 'error', 'Failed to recognize file format.');
      });
      expect(failures, hasLength(1));
      expect(failures.single.kind, PlaybackFailureKind.unreadable);
      expect(failures.single.generation, service.generation);
    });

    test('errors about something else stay in the log', () async {
      final failures = await collect(() async {
        await service.openFile(_file('film.mkv'));
        // A stale subtitle URL — the film itself is fine.
        player.emitLog(
          'cplayer',
          'error',
          'Can not open external file https://subs.example.invalid/1.srt.',
        );
        player.emitLog('vd', 'error', 'Error while decoding frame!');
      });
      expect(failures, isEmpty);
    });

    test('nothing is reported once the file is playing', () async {
      final failures = await collect(() async {
        await service.openFile(_file('film.mkv'));
        player.state = player.state.copyWith(
          duration: const Duration(hours: 2),
        );
        player.emitLog('cplayer', 'error', 'Failed to recognize file format.');
      });
      expect(failures, isEmpty);
    });

    test('nothing is reported after the player stops', () async {
      final failures = await collect(() async {
        await service.openFile(_file('film.mkv'));
        await service.stop();
        player.emitLog(
          'file',
          'error',
          "Cannot open file '/library/film.mkv': No such file or directory",
        );
      });
      expect(failures, isEmpty);
    });
  });

  group('classifyPlayerLog', () {
    PlaybackFailureKind? classify(
      String prefix,
      String text, {
      String level = 'error',
      String media = '/library/film.mkv',
    }) => classifyPlayerLog(
      PlayerLog(prefix: prefix, level: level, text: text),
      mediaUri: media,
    );

    test('a missing file', () {
      expect(
        classify(
          'file',
          "Cannot open file '/library/film.mkv': No such file or directory",
        ),
        PlaybackFailureKind.missingFile,
      );
      // …but not a missing sidecar subtitle beside it.
      expect(
        classify('file', "Cannot open file '/library/film.en.srt': gone"),
        isNull,
      );
    });

    test('a file mpv cannot read', () {
      expect(
        classify('cplayer', 'Failed to recognize file format.'),
        PlaybackFailureKind.unreadable,
      );
    });

    test('a stream whose proxy is gone', () {
      const url = 'http://127.0.0.1:53412/stream/0';
      expect(
        classify(
          'ffmpeg',
          'tcp: Connection to tcp://127.0.0.1:53412 failed: Connection refused',
          media: url,
        ),
        PlaybackFailureKind.streamUnavailable,
      );
      expect(
        classify('stream', 'Failed to open $url.', media: url),
        PlaybackFailureKind.streamUnavailable,
      );
      // A subtitle download failing on another host is not the stream.
      expect(
        classify(
          'ffmpeg',
          'tcp: Connection to tcp://subs.example.invalid:443 failed',
          media: url,
        ),
        isNull,
      );
    });

    test('warnings and recoverable decoder errors are not failures', () {
      expect(
        classify('cplayer', 'Failed to recognize file format.', level: 'warn'),
        isNull,
      );
      expect(classify('vd', 'Error while decoding frame!'), isNull);
    });
  });
}
