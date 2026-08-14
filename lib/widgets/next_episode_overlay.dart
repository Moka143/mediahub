import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import 'editorial/editorial.dart';

/// Compact "Up Next" prompt over the player.
///
/// Expanded: episode line plus three actions — Minimize, Dismiss, Play/Stream.
/// Minimized: countdown + code chip; tap restores. Countdown pauses while
/// collapsed so restoring does not instantly auto-play.
class NextEpisodeOverlay extends StatefulWidget {
  final String episodeCode;
  final String title;
  final int? countdownSeconds;
  final bool minimized;
  final String playLabel;
  final VoidCallback? onPlay;
  final VoidCallback onMinimize;
  final VoidCallback onDismiss;
  final VoidCallback onRestore;

  const NextEpisodeOverlay({
    super.key,
    required this.episodeCode,
    required this.title,
    this.countdownSeconds,
    required this.minimized,
    this.playLabel = 'Play',
    this.onPlay,
    required this.onMinimize,
    required this.onDismiss,
    required this.onRestore,
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

  bool get _hasCountdown => widget.countdownSeconds != null;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.countdownSeconds ?? 0;

    _animationController = AnimationController(
      duration: AppDuration.normal,
      vsync: this,
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0.12, 0.0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
        );
    _animationController.forward();

    if (_hasCountdown && !widget.minimized) {
      _startCountdown();
    }
  }

  @override
  void didUpdateWidget(NextEpisodeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.minimized == widget.minimized) return;
    if (widget.minimized) {
      _countdownTimer?.cancel();
      _countdownTimer = null;
    } else if (_hasCountdown) {
      _startCountdown();
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    if (_secondsRemaining <= 0) {
      widget.onPlay?.call();
      return;
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || widget.minimized) return;
      setState(() => _secondsRemaining--);
      if (_secondsRemaining <= 0) {
        timer.cancel();
        widget.onPlay?.call();
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: Material(
        color: Colors.transparent,
        child: AnimatedSize(
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          alignment: Alignment.centerRight,
          child: widget.minimized ? _buildMinimized() : _buildExpanded(),
        ),
      ),
    );
  }

  BoxDecoration _glass({double radius = AppRadius.full}) => BoxDecoration(
    color: Colors.black.withValues(alpha: 0.58),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: AppColors.lineStrong, width: 1),
  );

  Widget _buildMinimized() {
    return GestureDetector(
      onTap: widget.onRestore,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          decoration: _glass(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_hasCountdown) ...[
                MonoLabel(
                  '${_secondsRemaining}s',
                  color: AppColors.accent,
                  letterSpacing: 0.08,
                ),
                const SizedBox(width: 8),
              ],
              if (widget.episodeCode.isNotEmpty)
                MonoLabel(
                  widget.episodeCode,
                  color: AppColors.fg1,
                  uppercase: false,
                  letterSpacing: 0.06,
                ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_up_rounded,
                size: AppIconSize.sm,
                color: AppColors.fg2,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded() {
    return Container(
      width: 268,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: _glass(radius: AppRadius.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (_hasCountdown) ...[
                MonoLabel(
                  '${_secondsRemaining}s',
                  color: AppColors.accent,
                  letterSpacing: 0.08,
                ),
                const SizedBox(width: 8),
              ],
              if (widget.episodeCode.isNotEmpty) ...[
                MonoLabel(
                  widget.episodeCode,
                  color: AppColors.fg1,
                  uppercase: false,
                  letterSpacing: 0.06,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    size: 12,
                    color: AppColors.fg,
                    weight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _OverlayButton(
                  label: 'Minimize',
                  onTap: widget.onMinimize,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _OverlayButton(
                  label: 'Dismiss',
                  onTap: widget.onDismiss,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _OverlayButton(
                  label: widget.playLabel,
                  onTap: widget.onPlay,
                  emphasized: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.label,
    required this.onTap,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = !enabled
        ? AppColors.fg3
        : emphasized
        ? AppColors.bgPage
        : AppColors.fg1;
    final bg = !enabled
        ? AppColors.bgSurface.withValues(alpha: 0.4)
        : emphasized
        ? AppColors.accent
        : Colors.white.withValues(alpha: 0.08);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppType.ui(
              size: 11,
              color: fg,
              weight: emphasized ? FontWeight.w600 : FontWeight.w500,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }
}
