import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/providers/player_provider.dart';
import 'package:mediahub/services/playback_health_monitor.dart';
import 'package:mediahub/services/player_service.dart';
import 'package:mediahub/widgets/player/seek_bar.dart';

class _RecordingPlayerService extends PlayerService {
  _RecordingPlayerService(super.ref);

  final List<Duration> seeks = [];

  @override
  Future<void> seek(Duration position) async => seeks.add(position);
}

/// The seek bar's buffered run and the slider's click mapping must agree.
///
/// The grey track and the downloaded runs were painted across the bar's full
/// width while the slider mapped clicks onto a range inset by its overlay
/// radius at each end. Clicking the visible end of a 0–90% buffered run on
/// a bar this wide seeked past 91% — over a minute beyond the downloaded
/// edge of a two-hour film, straight into a stall.
void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  const film = Duration(hours: 2);

  /// Pump the bar; the service it seeks through is built on first use.
  Future<_RecordingPlayerService Function()> pumpBar(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    _RecordingPlayerService? service;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerServiceProvider.overrideWith(
            (ref) => service = _RecordingPlayerService(ref),
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const Scaffold(
            body: Center(
              child: SeekBar(
                position: Duration.zero,
                duration: film,
                bufferedRatio: 0,
                bufferedSpans: [BufferedSpan(0, 0.9)],
              ),
            ),
          ),
        ),
      ),
    );
    return () => service!;
  }

  Rect paintedTrack(WidgetTester tester) => tester.getRect(
    find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_BufferedTrackPainter',
    ),
  );

  double seekedFraction(_RecordingPlayerService Function() service) =>
      service().seeks.last.inMilliseconds / film.inMilliseconds;

  testWidgets('clicking the painted end of the buffered run seeks there', (
    tester,
  ) async {
    final service = await pumpBar(tester);
    final track = paintedTrack(tester);

    await tester.tapAt(Offset(track.left + 0.9 * track.width, track.center.dy));
    await tester.pump();

    // Within a pixel's worth of the edge, not 1.2% (86 s) past it.
    expect(seekedFraction(service), closeTo(0.9, 1 / track.width));

    // Dispose so the seek-settle timer does not outlive the test.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the slider spans the same width as the painted track', (
    tester,
  ) async {
    final service = await pumpBar(tester);
    final track = paintedTrack(tester);

    await tester.tapAt(Offset(track.left + 1, track.center.dy));
    await tester.pump();
    expect(seekedFraction(service), closeTo(0, 2 / track.width));

    await tester.tapAt(Offset(track.right - 1, track.center.dy));
    await tester.pump();
    expect(seekedFraction(service), closeTo(1, 2 / track.width));

    await tester.pumpWidget(const SizedBox());
  });
}
