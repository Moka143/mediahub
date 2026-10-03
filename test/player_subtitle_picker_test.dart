import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/providers/player_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/subtitle_provider.dart';
import 'package:mediahub/services/opensubtitles_service.dart';
import 'package:mediahub/services/player_service.dart';
import 'package:mediahub/widgets/player/track_buttons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_test_fakes.dart';

/// mpv takes a moment to fetch a subtitle URL — long enough for the picker
/// sheet to be gone when it finishes, which is the whole point.
class _SlowSubtitlePlayerService extends PlayerService {
  _SlowSubtitlePlayerService(super.ref, {this.fail = false});

  final bool fail;
  String? loaded;

  @override
  Future<void> loadExternalSubtitle(String path) async {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (fail) throw StateError('sub-add failed');
    loaded = path;
  }
}

/// Picking an OpenSubtitles language closes the sheet first and loads after.
///
/// The load used to finish by calling `ref.read` on the closed sheet's own
/// Consumer, which Riverpod rejects once it is unmounted: the subtitle
/// appeared, but the choice was never recorded or saved — and when the load
/// really failed, the error went to the closed sheet's context and the user
/// saw nothing.
void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  final file = LocalMediaFile(
    path: '/library/Arrival.2016.1080p.mkv',
    fileName: 'Arrival.2016.1080p.mkv',
    sizeBytes: 4 << 30,
    modifiedDate: DateTime(2026),
    extension: 'mkv',
  );
  final english = Subtitle(
    id: 'os-1',
    url: 'https://subs.example.invalid/os-1.srt',
    lang: 'eng',
    langName: 'English',
  );

  late SharedPreferences prefs;
  late FakePlayer player;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    player = FakePlayer();
  });

  tearDown(() => player.dispose());

  Future<(ProviderContainer, _SlowSubtitlePlayerService)> openPicker(
    WidgetTester tester, {
    bool fail = false,
  }) async {
    late _SlowSubtitlePlayerService service;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        playerProvider.overrideWithValue(player),
        playerServiceProvider.overrideWith(
          (ref) => service = _SlowSubtitlePlayerService(ref, fail: fail),
        ),
        availableSubtitlesProvider.overrideWith((ref) async => [english]),
      ],
    );
    addTearDown(container.dispose);
    // What the player does when it opens a file.
    container.read(currentExternalSubtitleProvider.notifier).beginFile(file);
    container
        .read(subtitleContextProvider.notifier)
        .setMovieContext('tt2543164');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const Scaffold(body: Center(child: SubtitleButton())),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    container.read(playerServiceProvider); // builds `service`
    return (container, service);
  }

  /// Frames 16 ms apart for [duration], so the closed sheet is unmounted
  /// long before the 1 s load completes.
  Future<void> runFor(WidgetTester tester, Duration duration) async {
    final frames = duration.inMilliseconds ~/ 16;
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('the choice is recorded and saved after the sheet closes', (
    tester,
  ) async {
    final (container, service) = await openPicker(tester);

    await tester.tap(find.text('English'));
    await runFor(tester, const Duration(seconds: 2));

    expect(service.loaded, english.url);
    expect(container.read(currentExternalSubtitleProvider)?.id, english.id);
    // Saved against this file, so the next playback of it loads it again.
    final selection = container.read(currentExternalSubtitleProvider.notifier);
    expect(selection.savedForCurrentFile()?.id, english.id);
    expect(
      prefs.getString('subtitle_pref:${subtitleCacheKeyFor(file)}'),
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed load says so, in plain words', (tester) async {
    final (container, _) = await openPicker(tester, fail: true);

    await tester.tap(find.text('English'));
    await runFor(tester, const Duration(seconds: 2));

    expect(
      find.text("Couldn't load the English subtitles. Try another."),
      findsOneWidget,
    );
    expect(find.textContaining('StateError'), findsNothing);
    expect(container.read(currentExternalSubtitleProvider), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
