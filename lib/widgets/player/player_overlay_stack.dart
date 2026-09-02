import 'package:flutter/material.dart';

import '../../design/app_tokens.dart';
import 'buffering_indicator.dart';
import 'resume_prompt.dart';
import 'seek_indicator.dart';
import 'skip_ripple_indicator.dart';

/// Everything drawn on top of the video, and the rules for when each piece
/// appears.
///
/// Step 4 of docs/player-screen-decomposition.md. This was ~150 lines inside
/// `video_player_screen.dart`'s `build()`, so none of the visibility rules
/// could be exercised without a real `Player`, a real torrent and a real
/// window. As a widget over plain values they are ordinary widget tests, and
/// the screen's `build()` drops to the frame around them.
///
/// The pieces that need a live stack — the video surface, the controls bar,
/// the Up Next chip and the status chip — arrive pre-built. What lives here
/// is the layering and the gating, which is the part that had no coverage:
///
///   * the buffering spinner needs media to be open, or it flashes over a
///     black frame during the initial decode;
///   * the resume prompt and the controls are mutually exclusive — the
///     prompt is a decision, and the controls behind it are not actionable;
///   * hidden controls are also inert (`IgnorePointer`), so a click in the
///     lower third does not hit an invisible button.
class PlayerOverlayStack extends StatelessWidget {
  const PlayerOverlayStack({
    super.key,
    required this.video,
    required this.showBuffering,
    required this.bufferingLabel,
    required this.showSkipForward,
    required this.showSkipBackward,
    required this.seekDelta,
    required this.seekStartTime,
    required this.showResumePrompt,
    required this.resumePosition,
    required this.onStartOver,
    required this.onResume,
    required this.controlsVisible,
    required this.controls,
    required this.upNextChip,
    required this.statusChip,
    required this.onTap,
    required this.onDoubleTap,
    required this.onHorizontalDragStart,
    required this.onHorizontalDragUpdate,
    required this.onHorizontalDragEnd,
  });

  /// The video surface, or null before the media is open.
  final Widget? video;

  final bool showBuffering;

  /// Text under the spinner. Null outside streaming, where there is no
  /// download percentage to report.
  final String? bufferingLabel;

  final bool showSkipForward;
  final bool showSkipBackward;

  /// Non-null together while a drag-to-seek is in progress.
  final double? seekDelta;
  final Duration? seekStartTime;

  final bool showResumePrompt;
  final Duration resumePosition;
  final VoidCallback onStartOver;
  final VoidCallback onResume;

  final bool controlsVisible;
  final Widget controls;

  /// Built by the caller from [UpNextChip]; null when it should not show.
  final Widget? upNextChip;

  /// Current-episode health-monitor chip; null when there is nothing to say.
  final Widget? statusChip;

  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final GestureDragStartCallback onHorizontalDragStart;
  final GestureDragUpdateCallback onHorizontalDragUpdate;
  final GestureDragEndCallback onHorizontalDragEnd;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Main video area with gesture detection
        GestureDetector(
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          onHorizontalDragStart: onHorizontalDragStart,
          onHorizontalDragUpdate: onHorizontalDragUpdate,
          onHorizontalDragEnd: onHorizontalDragEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ?video,

              // Buffering indicator — in streaming mode the label carries the
              // download progress, so a long pause-for-cache shows the user
              // the torrent is actually moving.
              if (showBuffering && video != null)
                BufferingIndicator(label: bufferingLabel),

              // Skip backward indicator (left side)
              if (showSkipBackward)
                const Positioned(
                  left: 60,
                  top: 0,
                  bottom: 0,
                  child: Center(child: SkipRippleIndicator(forward: false)),
                ),

              // Skip forward indicator (right side)
              if (showSkipForward)
                const Positioned(
                  right: 60,
                  top: 0,
                  bottom: 0,
                  child: Center(child: SkipRippleIndicator(forward: true)),
                ),

              // Seek indicator during drag
              if (seekDelta != null && seekStartTime != null)
                Center(
                  child: SeekIndicator(
                    seekDelta: seekDelta!,
                    dragStartTime: seekStartTime!,
                  ),
                ),

              // Resume prompt overlay
              if (showResumePrompt)
                ResumePrompt(
                  resumePosition: resumePosition,
                  onStartOver: onStartOver,
                  onResume: onResume,
                ),

              // Custom controls overlay
              if (!showResumePrompt)
                AnimatedOpacity(
                  opacity: controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: IgnorePointer(
                    ignoring: !controlsVisible,
                    child: controls,
                  ),
                ),
            ],
          ),
        ),

        // Up Next chip — sized to itself so player controls stay tappable.
        if (upNextChip != null)
          Positioned(right: AppSpacing.lg, bottom: 110, child: upNextChip!),

        // Current-episode health-monitor chip (the next-episode prefetch is
        // the spinner beside the Continue Watching pill).
        if (statusChip != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + AppSpacing.md,
            left: 0,
            right: 0,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: statusChip!,
              ),
            ),
          ),
      ],
    );
  }
}
