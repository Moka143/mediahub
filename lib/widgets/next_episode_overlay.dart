import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/app_tokens.dart';
import '../models/local_media_file.dart';

/// Overlay widget shown near the end of an episode to prompt
/// the user to play the next episode (binge watching feature).
class NextEpisodeOverlay extends StatefulWidget {
  final LocalMediaFile nextEpisode;
  final int countdownSeconds;
  final VoidCallback onPlayNext;
  final VoidCallback onCancel;
  final VoidCallback? onWatchCredits;

  const NextEpisodeOverlay({
    super.key,
    required this.nextEpisode,
    required this.countdownSeconds,
    required this.onPlayNext,
    required this.onCancel,
    this.onWatchCredits,
  });

  @override
  State<NextEpisodeOverlay> createState() => _NextEpisodeOverlayState();
}

class _NextEpisodeOverlayState extends State<NextEpisodeOverlay>
    with SingleTickerProviderStateMixin {
  late int _secondsRemaining;
  Timer? _countdownTimer;
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.countdownSeconds;

    // Slide in from the right
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 420),
      vsync: this,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));
    _animationController.forward();

    _startCountdown();
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _secondsRemaining--);
      if (_secondsRemaining <= 0) {
        timer.cancel();
        widget.onPlayNext();
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  /// Fraction of countdown that has elapsed (0.0 → 1.0).
  double get _progress =>
      (_secondsRemaining / widget.countdownSeconds).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final episode = widget.nextEpisode;

    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.only(right: AppSpacing.xl, bottom: 110),
        child: SlideTransition(
          position: _slideAnimation,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 340,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.88),
                borderRadius: BorderRadius.circular(AppRadius.xl),
                border: Border.all(
                  color: theme.colorScheme.primary.withOpacity(0.25),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  _buildHeader(theme),
                  // Episode info
                  _buildEpisodeInfo(theme, episode),
                  // Action buttons
                  _buildActions(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.18),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(AppRadius.xl),
          topRight: Radius.circular(AppRadius.xl),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.skip_next_rounded, color: theme.colorScheme.primary, size: 18),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              'Up Next',
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Circular countdown ring
          _CircularCountdown(
            secondsRemaining: _secondsRemaining,
            progress: _progress,
            color: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeInfo(ThemeData theme, LocalMediaFile episode) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Thumbnail placeholder with play icon
          Container(
            width: 90,
            height: 56,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withOpacity(0.3),
                  theme.colorScheme.primary.withOpacity(0.1),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Icon(
              Icons.play_circle_outline_rounded,
              color: Colors.white.withOpacity(0.85),
              size: 30,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (episode.episodeCode != null)
                  Text(
                    episode.episodeCode!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                const SizedBox(height: 3),
                Text(
                  episode.showName ?? episode.fileName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (episode.quality != null) ...[
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      episode.quality!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white60,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          // Cancel
          Expanded(
            child: OutlinedButton(
              onPressed: widget.onCancel,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // Play Now (primary)
          Expanded(
            flex: 2,
            child: FilledButton.icon(
              onPressed: widget.onPlayNext,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('Play Now'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Circular countdown ring widget
// ---------------------------------------------------------------------------

class _CircularCountdown extends StatelessWidget {
  final int secondsRemaining;
  final double progress; // 1.0 = full, 0.0 = empty
  final Color color;
  static const double _size = 38.0;
  static const double _strokeWidth = 3.0;

  const _CircularCountdown({
    required this.secondsRemaining,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background track
          CustomPaint(
            size: const Size(_size, _size),
            painter: _RingPainter(
              progress: 1.0,
              color: Colors.white.withOpacity(0.12),
              strokeWidth: _strokeWidth,
            ),
          ),
          // Progress arc
          CustomPaint(
            size: const Size(_size, _size),
            painter: _RingPainter(
              progress: progress,
              color: color,
              strokeWidth: _strokeWidth,
            ),
          ),
          // Countdown number
          Text(
            '$secondsRemaining',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  const _RingPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.width - strokeWidth) / 2,
    );

    // Start from the top (−π/2) and sweep clockwise
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}
