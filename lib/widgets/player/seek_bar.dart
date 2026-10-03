import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../providers/player_provider.dart';
import '../../services/playback_health_monitor.dart';
import '../../utils/formatters.dart';

/// [SeekBar] fed from the player.
///
/// The position, duration and buffer are watched here rather than by the
/// controls overlay around it. mpv reports position about once a frame, and
/// watching it at the top of the overlay rebuilt every control in the bar —
/// even while they were faded out — to move one thumb.
class PlayerSeekBar extends ConsumerWidget {
  const PlayerSeekBar({
    super.key,
    this.streamingDownloadedRatio,
    this.bufferedSpans = const [],
  });

  /// The file's download fraction while streaming, which overrides mpv's
  /// demuxer cache for the buffered track. mpv's cache reflects what the
  /// demuxer has read, which from a sparse torrent file may include
  /// zero-region over-reads — useless as a seek hint.
  final double? streamingDownloadedRatio;

  /// Where the downloaded bytes are, from the torrent's piece map. Takes
  /// precedence over [streamingDownloadedRatio] when non-empty.
  final List<BufferedSpan> bufferedSpans;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final duration = ref.watch(playbackDurationProvider).value ?? Duration.zero;
    final buffered = ref.watch(playbackBufferProvider).value ?? Duration.zero;

    final ratio = streamingDownloadedRatio;
    final bufferedRatio = ratio != null
        ? ratio.clamp(0.0, 1.0)
        : duration.inMilliseconds > 0
        ? (buffered.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return SeekBar(
      position: position,
      duration: duration,
      bufferedRatio: bufferedRatio,
      bufferedSpans: bufferedSpans,
    );
  }
}

/// Seek bar with a piece-accurate buffered track.
///
/// Three things it has to get right, none of which the earlier versions did:
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
///
/// **Click where it is drawn.** The grey track and the buffered runs span the
/// bar's full width, but a default [Slider] insets its own track by the
/// thumb's overlay radius and maps clicks onto that narrower range. Clicking
/// the visible end of a 0–90% buffered run on a wide bar seeked to 91% — a
/// minute and more past the downloaded edge of a film, straight into a
/// stall. The slider here has no padding, so its track is the bar.
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

  static const double _barHeight = 24;
  static const double _trackHeight = 4;
  static const double _thumbRadius = 6;
  static const double _overlayRadius = 12;

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
    unawaited(
      ref
          .read(playerServiceProvider)
          .seek(Duration(milliseconds: (value * durationMs).round())),
    );
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
    final timeStyle = AppType.mono(
      size: AppType.sizeCaption,
      color: AppColors.onMedia,
    );

    return Row(
      children: [
        Text(
          Formatters.formatPlaybackDuration(displayPosition),
          style: timeStyle,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: SizedBox(
            height: _barHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Inactive track (full width, darkened)
                Container(
                  height: _trackHeight,
                  decoration: BoxDecoration(
                    color: AppColors.onMedia.withAlpha(AppOpacity.medium),
                    borderRadius: BorderRadius.circular(_trackHeight / 2),
                  ),
                ),
                // Buffered runs — lighter, behind the slider.
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BufferedTrackPainter(
                      spans: spans,
                      color: AppColors.onMedia.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                // Slider — transparent inactive track so the layers above
                // show through, and no padding so its track is the same
                // full width they are drawn across (see the class doc).
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: _trackHeight,
                    padding: EdgeInsets.zero,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: _thumbRadius,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: _overlayRadius,
                    ),
                    activeTrackColor: theme.colorScheme.primary,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: AppColors.onMedia,
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
        const SizedBox(width: AppSpacing.sm),
        Text(
          Formatters.formatPlaybackDuration(widget.duration),
          style: timeStyle,
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
          const Radius.circular(_trackHeight / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BufferedTrackPainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.spans, spans);
}
