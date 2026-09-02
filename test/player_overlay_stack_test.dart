import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/widgets/player/buffering_indicator.dart';
import 'package:mediahub/widgets/player/player_overlay_stack.dart';
import 'package:mediahub/widgets/player/resume_prompt.dart';
import 'package:mediahub/widgets/player/seek_indicator.dart';
import 'package:mediahub/widgets/player/skip_ripple_indicator.dart';

/// Widget tests for the player's overlay layering.
///
/// These rules lived inside `video_player_screen.dart`'s `build()` until step
/// 4 of docs/player-screen-decomposition.md, tangled with a `Player`, a
/// `VideoController` and a `windowManager`. None of them had coverage, and
/// each one is a thing a user notices immediately when it breaks: a spinner
/// over a black frame, a resume dialog with live controls behind it, or an
/// invisible button that still swallows clicks.
void main() {
  const video = ColoredBox(key: Key('video'), color: Colors.black);
  const controls = SizedBox(key: Key('controls'), width: 10, height: 10);

  Future<void> pump(
    WidgetTester tester, {
    Widget? video,
    bool showBuffering = false,
    String? bufferingLabel,
    bool showSkipForward = false,
    bool showSkipBackward = false,
    double? seekDelta,
    Duration? seekStartTime,
    bool showResumePrompt = false,
    bool controlsVisible = true,
    Widget? upNextChip,
    Widget? statusChip,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: PlayerOverlayStack(
            video: video,
            showBuffering: showBuffering,
            bufferingLabel: bufferingLabel,
            showSkipForward: showSkipForward,
            showSkipBackward: showSkipBackward,
            seekDelta: seekDelta,
            seekStartTime: seekStartTime,
            showResumePrompt: showResumePrompt,
            resumePosition: const Duration(minutes: 12),
            onStartOver: () {},
            onResume: () {},
            controlsVisible: controlsVisible,
            controls: controls,
            upNextChip: upNextChip,
            statusChip: statusChip,
            onTap: () {},
            onDoubleTap: () {},
            onHorizontalDragStart: (_) {},
            onHorizontalDragUpdate: (_) {},
            onHorizontalDragEnd: (_) {},
          ),
        ),
      ),
    );
  }

  IgnorePointer nearestIgnorePointer(WidgetTester tester) => tester
      .widgetList<IgnorePointer>(
        find.ancestor(
          of: find.byKey(const Key('controls')),
          matching: find.byType(IgnorePointer),
        ),
      )
      .first;

  AnimatedOpacity nearestOpacity(WidgetTester tester) => tester
      .widgetList<AnimatedOpacity>(
        find.ancestor(
          of: find.byKey(const Key('controls')),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .first;

  group('buffering spinner', () {
    testWidgets('waits for the media to be open', (tester) async {
      // Otherwise it flashes over a black frame during the initial decode,
      // right after the streaming overlay has just been dismissed.
      await pump(tester, video: null, showBuffering: true);
      expect(find.byType(BufferingIndicator), findsNothing);
    });

    testWidgets('shows once media is open and buffering', (tester) async {
      await pump(tester, video: video, showBuffering: true);
      expect(find.byType(BufferingIndicator), findsOneWidget);
    });

    testWidgets('carries the download label when streaming', (tester) async {
      await pump(
        tester,
        video: video,
        showBuffering: true,
        bufferingLabel: 'Buffering — 12.5% downloaded',
      );
      expect(find.text('Buffering — 12.5% downloaded'), findsOneWidget);
    });
  });

  group('resume prompt', () {
    testWidgets('replaces the controls rather than stacking on them', (
      tester,
    ) async {
      // The prompt is a decision; the controls behind it are not actionable
      // and a half-lit controls bar under a dialog reads as a broken frame.
      await pump(tester, video: video, showResumePrompt: true);
      expect(find.byType(ResumePrompt), findsOneWidget);
      expect(find.byKey(const Key('controls')), findsNothing);
    });

    testWidgets('yields to the controls once dismissed', (tester) async {
      await pump(tester, video: video);
      expect(find.byType(ResumePrompt), findsNothing);
      expect(find.byKey(const Key('controls')), findsOneWidget);
    });
  });

  group('controls', () {
    testWidgets('hidden controls are also inert', (tester) async {
      // Faded-out controls that still take pointers mean a click in the lower
      // third hits an invisible button.
      await pump(tester, video: video, controlsVisible: false);
      // `.first` is the nearest ancestor — MaterialApp and Scaffold
      // contribute their own further out.
      expect(nearestIgnorePointer(tester).ignoring, isTrue);
      expect(nearestOpacity(tester).opacity, 0.0);
    });

    testWidgets('visible controls accept pointers', (tester) async {
      await pump(tester, video: video);
      expect(nearestIgnorePointer(tester).ignoring, isFalse);
      expect(nearestOpacity(tester).opacity, 1.0);
    });
  });

  group('skip and seek indicators', () {
    testWidgets('each side shows independently', (tester) async {
      await pump(tester, video: video, showSkipBackward: true);
      expect(find.byType(SkipRippleIndicator), findsOneWidget);
      expect(
        tester
            .widget<SkipRippleIndicator>(find.byType(SkipRippleIndicator))
            .forward,
        isFalse,
      );
    });

    testWidgets('the seek readout needs both a delta and a start', (
      tester,
    ) async {
      // They are set and cleared together by the drag handlers; a delta with
      // no start time used to throw on a `!` in build().
      await pump(tester, video: video, seekDelta: 30);
      expect(find.byType(SeekIndicator), findsNothing);

      await pump(
        tester,
        video: video,
        seekDelta: 30,
        seekStartTime: const Duration(minutes: 5),
      );
      expect(find.byType(SeekIndicator), findsOneWidget);
    });
  });

  group('corner chips', () {
    testWidgets('are absent unless supplied', (tester) async {
      await pump(tester, video: video);
      expect(find.byKey(const Key('upnext')), findsNothing);
      expect(find.byKey(const Key('status')), findsNothing);
    });

    testWidgets('both can be on screen at once', (tester) async {
      // The Up Next chip sits bottom-right and the health chip top-centre
      // precisely so a stream that is struggling can still offer the next
      // episode.
      await pump(
        tester,
        video: video,
        upNextChip: const SizedBox(key: Key('upnext'), width: 10, height: 10),
        statusChip: const SizedBox(key: Key('status'), width: 10, height: 10),
      );
      expect(find.byKey(const Key('upnext')), findsOneWidget);
      expect(find.byKey(const Key('status')), findsOneWidget);
    });

    testWidgets('survive the resume prompt', (tester) async {
      // They live outside the gesture layer the prompt replaces.
      await pump(
        tester,
        video: video,
        showResumePrompt: true,
        statusChip: const SizedBox(key: Key('status'), width: 10, height: 10),
      );
      expect(find.byKey(const Key('status')), findsOneWidget);
    });
  });
}
