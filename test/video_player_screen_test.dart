import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/providers/player_provider.dart';
import 'package:mediahub/providers/settings_provider.dart';
import 'package:mediahub/providers/subtitle_provider.dart';
import 'package:mediahub/screens/video_player_screen.dart';
import 'package:mediahub/services/opensubtitles_service.dart';
import 'package:mediahub/widgets/player/player_error_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_test_fakes.dart';

/// The player screen's lifecycle against a fake libmpv.
///
/// Opening a file can take seconds — `openFile` waits up to six for a
/// duration before a resume seek — and everything here is about the user not
/// waiting for it: leaving mid-open, a file that never opens at all, and the
/// app-wide state the previous video left behind. The open is held in flight
/// throughout, which is also why no video surface is ever built.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  stubWindowManager();

  final film = LocalMediaFile(
    path: '/library/Arrival.2016.1080p.mkv',
    fileName: 'Arrival.2016.1080p.mkv',
    sizeBytes: 4 << 30,
    modifiedDate: DateTime(2026),
    extension: 'mkv',
  );
  const proxyUrl = 'http://127.0.0.1:53412/stream/0';

  late FakePlayer player;
  late SharedPreferences prefs;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    player = FakePlayer()..openGate = Completer<void>();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        playerProvider.overrideWithValue(player),
        // No network: OpenSubtitles answers with nothing, at once.
        availableSubtitlesProvider.overrideWith((ref) async => const []),
      ],
    );
  });

  tearDown(() async {
    if (!(player.openGate?.isCompleted ?? true)) player.openGate!.complete();
    container.dispose();
    await player.dispose();
  });

  /// Take the whole tree down, so nothing outlives the test's container.
  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  /// Push [screen] from a home page, and let it start opening its file.
  /// Returns what the player route was popped with.
  Future<Future<Object?>> pushPlayer(
    WidgetTester tester,
    VideoPlayerScreen screen,
  ) async {
    late Future<Object?> popped;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => popped = Navigator.of(
                  context,
                ).push<Object?>(MaterialPageRoute(builder: (_) => screen)),
                child: const Text('home'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(player.opened, [screen.streamingProxyUrl ?? film.path]);
    return popped;
  }

  testWidgets('leaving while the file is still opening stops it', (
    tester,
  ) async {
    // The back path only stopped the player once the open had returned, so
    // a file still opening played on with nothing on screen to stop it.
    await pushPlayer(tester, VideoPlayerScreen(file: film));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(player.calls.last, 'stop');

    // The open finishes after the screen has gone. It must not go on to
    // play, seek or be stopped twice.
    player.calls.clear();
    player.openGate!.complete();
    await tester.pumpAndSettle();
    expect(player.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('a route removed from under the player still stops it', (
    tester,
  ) async {
    // Not every exit goes through the back button: the navigator can pop or
    // replace the route itself. Dispose stops what this screen started.
    await pushPlayer(tester, VideoPlayerScreen(file: film));
    player.calls.clear();

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(player.calls, ['stop']);
    await unmount(tester);
  });

  testWidgets('a file that cannot be played says so', (tester) async {
    await pushPlayer(tester, VideoPlayerScreen(file: film));

    player.emitLog('cplayer', 'error', 'Failed to recognize file format.');
    // One pump delivers the log line and the failure, the next draws it.
    await tester.pump();
    await tester.pump();

    expect(find.byType(PlayerErrorOverlay), findsOneWidget);
    expect(
      find.textContaining('may not have finished downloading'),
      findsOneWidget,
    );
    // A file on disk has no other source to try.
    expect(find.text('Try another source'), findsNothing);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a failed stream can go back for another source', (tester) async {
    final popped = await pushPlayer(
      tester,
      VideoPlayerScreen(
        file: film,
        isStreaming: true,
        streamingProxyUrl: proxyUrl,
      ),
    );

    player.emitLog('stream', 'error', 'Failed to open $proxyUrl.');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('stream stopped responding'), findsOneWidget);

    await tester.tap(find.text('Try another source'));
    await tester.pumpAndSettle();
    expect(await popped, PlayerExitReason.tryAnotherSource);
    await unmount(tester);
  });

  testWidgets("a new file starts without the last one's subtitles", (
    tester,
  ) async {
    // Both live in app-wide providers. A Library file opens with no IMDB id
    // of its own, and used to list and load the previous movie's subtitles.
    container.read(subtitleContextProvider.notifier).setMovieContext('tt-old');
    container
        .read(currentExternalSubtitleProvider.notifier)
        .set(
          Subtitle(
            id: 'old',
            url: 'https://subs.example.invalid/old.srt',
            lang: 'eng',
          ),
        );

    await pushPlayer(tester, VideoPlayerScreen(file: film));

    expect(container.read(subtitleContextProvider), isNull);
    expect(container.read(currentExternalSubtitleProvider), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await unmount(tester);
  });

  testWidgets('a movie opened with its IMDB id gets that subtitle query', (
    tester,
  ) async {
    container
        .read(subtitleContextProvider.notifier)
        .setSeriesContext(imdbId: 'tt-old-show', season: 1, episode: 1);

    await pushPlayer(
      tester,
      VideoPlayerScreen(file: film, movieImdbId: 'tt2543164'),
    );

    final query = container.read(subtitleContextProvider);
    expect(query?.imdbId, 'tt2543164');
    expect(query?.isMovie, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await unmount(tester);
  });
}
