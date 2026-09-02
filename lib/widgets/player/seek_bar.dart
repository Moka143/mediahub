import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_tokens.dart';
import '../../providers/player_provider.dart';
import '../../services/playback_health_monitor.dart';
import '../../utils/formatters.dart';

/// Seek bar with a piece-accurate buffered track.
///
/// Two things it has to get right, neither of which the earlier inline
/// version did:
///
/// **Seek once, on release.** `Slider.onChanged` fires continuously during a
/// drag, and it used to call `seek()` on every one of those callbacks —
/// dozens of seeks per second. Against the local HTTP proxy each seek makes
/// mpv abandon its in-flight range request and open a new one at a new
/// offset, so a single drag became a storm of half-finished reads and the
/// player sat on the spinner well after the drag ended. The thumb now
/// follows the pointer locally and exactly one seek is issued, on release.
///
/// **Draw where the bytes are, not just how many.** See [BufferedSpan].
class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.bufferedRatio,
    required this.bufferedSpans,
  });

  final Duration position;
  final Duration duration;

  /// Single-run fraction used when [bufferedSpans] is empty — local playback,
  /// or a stream whose piece map we couldn't read.
  final double bufferedRatio;

  final List<BufferedSpan> bufferedSpans;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  /// How close mpv's reported position must get to the seek target before we
  /// hand the thumb back to playback. Without this the thumb snaps back to
  /// where it started for a frame or two after release, because a seek over
  /// the proxy takes a moment to land.
  static const Duration _seekSettleTolerance = Duration(seconds: 2);

  /// Stop waiting for the seek to land after this, so one that never
  /// completes doesn't pin the thumb to a stale target forever.
  static const Duration _seekSettleTimeout = Duration(seconds: 15);

  /// Slider value while the pointer is down. Null when not dragging.
  double? _dragValue;

  /// Seek target already issued, held until playback catches up to it.
  double? _pendingValue;
  Timer? _pendingTimer;

  @override
  void didUpdateWidget(covariant SeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pending = _pendingValue;
    final durationMs = widget.duration.inMilliseconds;
    if (pending == null || durationMs <= 0) return;
    final targetMs = (pending * durationMs).round();
    if ((widget.position.inMilliseconds - targetMs).abs() <
        _seekSettleTolerance.inMilliseconds) {
      // Plain assignment, no setState: didUpdateWidget runs as part of this
      // rebuild, so build() below already sees the cleared value.
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _pendingValue = null;
    }
  }

  @override
  void dispose() {
    _pendingTimer?.cancel();
    super.dispose();
  }

  void _commitSeek(double value, int durationMs) {
    _pendingTimer?.cancel();
    setState(() {
      _dragValue = null;
      _pendingValue = value;
    });
    _pendingTimer = Timer(_seekSettleTimeout, () {
      if (mounted) setState(() => _pendingValue = null);
    });
    ref
        .read(playerServiceProvider)
        .seek(Duration(milliseconds: (value * durationMs).round()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durationMs = widget.duration.inMilliseconds;
    final hasDuration = durationMs > 0;

    final playbackValue = hasDuration
        ? (widget.position.inMilliseconds / durationMs).clamp(0.0, 1.0)
        : 0.0;
    final value = _dragValue ?? _pendingValue ?? playbackValue;
    final displayPosition = hasDuration
        ? Duration(milliseconds: (value * durationMs).round())
        : widget.position;

    final spans = widget.bufferedSpans.isNotEmpty
        ? widget.bufferedSpans
        : [BufferedSpan(0, widget.bufferedRatio)];

    return Row(
      children: [
        Text(
          Formatters.formatPlaybackDuration(displayPosition),
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        SizedBox(width: AppSpacing.sm),
        Expanded(
          child: SizedBox(
            height: 24,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Inactive track (full width, darkened)
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Buffered runs — lighter, behind the slider.
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BufferedTrackPainter(
                      spans: spans,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                // Slider — transparent tracks so the buffered layer shows
                // through.
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    activeTrackColor: theme.colorScheme.primary,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: value,
                    onChanged: hasDuration
                        ? (v) => setState(() => _dragValue = v)
                        : null,
                    onChangeEnd: hasDuration
                        ? (v) => _commitSeek(v, durationMs)
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(width: AppSpacing.sm),
        Text(
          Formatters.formatPlaybackDuration(widget.duration),
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    );
  }
}

/// Paints the downloaded runs of the file onto the seek bar.
///
/// A run narrower than [_minSpanWidth] is widened to it, so a single landed
/// piece still shows rather than rounding away to nothing.
class _BufferedTrackPainter extends CustomPainter {
  const _BufferedTrackPainter({required this.spans, required this.color});

  static const double _minSpanWidth = 2;
  static const double _trackHeight = 4;

  final List<BufferedSpan> spans;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0) return;
    final paint = Paint()..color = color;
    final top = (size.height - _trackHeight) / 2;
    for (final span in spans) {
      final left = (span.start * size.width).clamp(0.0, size.width);
      final right = (span.end * size.width).clamp(0.0, size.width);
      var width = right - left;
      if (width <= 0) continue;
      if (width < _minSpanWidth) width = _minSpanWidth;
      if (left + width > size.width) width = size.width - left;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, width, _trackHeight),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BufferedTrackPainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.spans, spans);
}
