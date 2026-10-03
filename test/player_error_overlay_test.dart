import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/models/playback_failure.dart';
import 'package:mediahub/widgets/player/player_error_overlay.dart';

/// What the player says when a file can't be played. mpv's errors used to
/// reach the log only, leaving a black screen and a spinner.
void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  PlaybackFailure failure(PlaybackFailureKind kind) => PlaybackFailure(
    kind: kind,
    generation: 1,
    detail: 'cplayer: Failed to recognize file format.',
  );

  test('every failure has a plain sentence, never mpv text', () {
    for (final kind in PlaybackFailureKind.values) {
      for (final streaming in [true, false]) {
        final message = playbackFailureMessage(
          failure(kind),
          streaming: streaming,
        );
        expect(message, isNotEmpty);
        expect(message, isNot(contains('cplayer')));
        expect(message, endsWith('.'));
      }
    }
  });

  test('a stream error is shown only when it reads as a sentence', () {
    expect(
      presentableStreamError('No peers for this source. Try another.'),
      'No peers for this source. Try another.',
    );
    expect(presentableStreamError('Error: SocketException: refused'), isNull);
    expect(presentableStreamError('DioException [bad response]'), isNull);
    expect(presentableStreamError(null), isNull);
    expect(presentableStreamError('  '), isNull);
  });

  Future<(List<String>, Widget)> pumpOverlay(
    WidgetTester tester, {
    required bool streaming,
  }) async {
    final calls = <String>[];
    final overlay = PlayerErrorOverlay(
      message: playbackFailureMessage(
        failure(PlaybackFailureKind.unreadable),
        streaming: streaming,
      ),
      onBack: () => calls.add('back'),
      onTryAnotherSource: streaming ? () => calls.add('another') : null,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(body: overlay),
      ),
    );
    return (calls, overlay);
  }

  testWidgets('a stream offers another source', (tester) async {
    final (calls, _) = await pumpOverlay(tester, streaming: true);

    expect(find.text("Can't play this video"), findsOneWidget);
    await tester.tap(find.text('Try another source'));
    await tester.tap(find.text('Back'));
    expect(calls, ['another', 'back']);
  });

  testWidgets('a file on disk offers only Back', (tester) async {
    final (calls, _) = await pumpOverlay(tester, streaming: false);

    expect(find.text('Try another source'), findsNothing);
    await tester.tap(find.text('Back'));
    expect(calls, ['back']);
  });
}
