import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/providers/player_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/widgets/player/track_buttons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_test_fakes.dart';

/// The audio and subtitle pickers against what media_kit actually reports.
///
/// media_kit lists two pseudo-tracks — `auto` and `no` — ahead of the real
/// ones on every file. Shown as tracks they offered "Track auto" and "Track
/// no", choosing "Track no" for audio silently muted playback, and a file
/// with one real audio track counted three, so the Audio button never hid.
void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  late FakePlayer player;
  late SharedPreferences prefs;

  setUp(() async {
    player = FakePlayer();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() => player.dispose());

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerProvider.overrideWithValue(player),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
  }

  Future<void> reportTracks(
    WidgetTester tester, {
    List<AudioTrack> audio = const [],
    List<SubtitleTrack> subtitle = const [],
  }) async {
    // As media_kit does: the two modes first, then the file's own tracks.
    player.tracks.add(
      Tracks(
        audio: [AudioTrack.auto(), AudioTrack.no(), ...audio],
        subtitle: [SubtitleTrack.auto(), SubtitleTrack.no(), ...subtitle],
      ),
    );
    await tester.pump();
  }

  group('Audio', () {
    testWidgets('one real track hides the button', (tester) async {
      await pump(tester, const AudioTrackButton());
      await reportTracks(tester, audio: [const AudioTrack('1', null, 'eng')]);

      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('the picker lists only real tracks', (tester) async {
      await pump(tester, const AudioTrackButton());
      await reportTracks(
        tester,
        audio: [
          const AudioTrack('1', null, 'eng'),
          const AudioTrack('2', null, 'fre'),
        ],
      );

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(find.text('eng'), findsOneWidget);
      expect(find.text('fre'), findsOneWidget);
      expect(find.text('Track auto'), findsNothing);
      expect(find.text('Track no'), findsNothing);

      await tester.tap(find.text('fre'));
      await tester.pumpAndSettle();
      expect(player.audioTracksSet.single.id, '2');
    });
  });

  group('Subtitles', () {
    testWidgets('the picker has its own Off, and no pseudo-tracks', (
      tester,
    ) async {
      await pump(tester, const SubtitleButton());
      await reportTracks(
        tester,
        subtitle: [const SubtitleTrack('3', 'Commentary', 'eng')],
      );

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Commentary'), findsOneWidget);
      expect(find.text('Track auto'), findsNothing);
      expect(find.text('Track no'), findsNothing);

      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(player.subtitleTracksSet.single.id, 'no');
    });

    testWidgets('a file with no subtitles at all hides the button', (
      tester,
    ) async {
      await pump(tester, const SubtitleButton());
      await reportTracks(tester);

      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('tooltips advertise no shortcut keys', (tester) async {
      // They promised C, A and S, which nothing handled.
      await pump(
        tester,
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SubtitleButton(),
            AudioTrackButton(),
            PlaybackSpeedButton(),
          ],
        ),
      );
      await reportTracks(
        tester,
        audio: [
          const AudioTrack('1', null, 'eng'),
          const AudioTrack('2', null, 'fre'),
        ],
        subtitle: [const SubtitleTrack('3', null, 'eng')],
      );

      final messages = tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((t) => t.message)
          .toList();
      expect(messages, containsAll(['Subtitles', 'Audio track']));
      expect(messages, contains('Playback speed'));
      for (final message in messages) {
        expect(message, isNot(matches(RegExp(r'\([A-Z]\)'))));
      }
    });
  });
}
