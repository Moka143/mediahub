import 'dart:async';

import 'package:flutter/material.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/episode.dart';
import '../models/local_media_file.dart';
import 'common/hub_pressable.dart';
import 'editorial/editorial.dart';

/// What the Up Next card should say, or null when it should not appear.
///
/// The view model for [NextEpisodeOverlay], kept beside it. These five rules
/// used to be inline conditionals and `??` chains inside
/// `video_player_screen.dart`'s `build()`, where the only way to check them
/// was to watch an episode to the credits with a real torrent behind it:
///
///   * the card appears only while the planner is offering it *and* some
///     next episode is known — either a file already on disk or a TMDB
///     answer;
///   * a file on disk plays immediately, so the button reads Play and a
///     countdown runs; a TMDB-only episode has to be fetched first, so it
///     reads Stream and there is nothing to count down to;
///   * the title prefers the show name, falls back to the file name for a
///     download whose name never got parsed, and to TMDB's episode name when
///     there is no file yet;
///   * an episode code may be missing on either source, and an empty string
///     is what the overlay expects in that case.
@immutable
class UpNextModel {
  const UpNextModel({
    required this.episodeCode,
    required this.title,
    required this.playsFromDisk,
    required this.countdownSeconds,
  });

  /// `S02E04`, or empty when neither source carries one.
  final String episodeCode;

  /// Show name, file name, or the TMDB episode title — in that order.
  final String title;

  /// True when the episode is already on disk. Drives the button label, and
  /// is the difference between playing and starting a new stream.
  final bool playsFromDisk;

  /// Seconds until auto-advance, or null when there is nothing to advance to
  /// yet (the TMDB-only case).
  final int? countdownSeconds;

  /// Play for a file we have, Stream for one we would have to fetch.
  String get playLabel => playsFromDisk ? 'Play' : 'Stream';

  /// Returns null when the card should not be shown at all.
  static UpNextModel? resolve({
    required bool overlayActive,
    required LocalMediaFile? downloaded,
    required Episode? fromTmdb,
    required int countdownSeconds,
  }) {
    if (!overlayActive) return null;
    if (downloaded == null && fromTmdb == null) return null;

    if (downloaded != null) {
      return UpNextModel(
        episodeCode: downloaded.episodeCode ?? '',
        title: downloaded.showName ?? downloaded.fileName,
        playsFromDisk: true,
        countdownSeconds: countdownSeconds,
      );
    }
    return UpNextModel(
      episodeCode: fromTmdb!.episodeCode,
      title: fromTmdb.name,
      playsFromDisk: false,
      countdownSeconds: null,
    );
  }
}

/// Compact "Up Next" prompt over the player.
///
/// Expanded: episode line plus three actions — Minimize, Dismiss, Play/Stream.
/// Minimized: countdown + code chip; click restores. The countdown pauses
/// while collapsed so restoring does not instantly auto-play.
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
  static const double _expandedWidth = 268;
  static const double _glassAlpha = 0.58;
  static const double _gap = 6;

  /// The card counts down in whole seconds.
  static const Duration _countdownTick = Duration(seconds: 1);

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

    if (_hasCountdown && !widget.minimized) _startCountdown();
  }

  @override
  void didUpdateWidget(NextEpisodeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    // The countdown can arrive after the card is already up: a TMDB-only
    // episode (Stream, no countdown) becomes a file on disk (Play, counting
    // down) when its prefetch finishes during the credits. This used to look
    // only at `minimized`, so the card sat on a frozen "0s" and never played.
    if (oldWidget.countdownSeconds != widget.countdownSeconds) {
      final seconds = widget.countdownSeconds;
      _stopCountdown();
      if (seconds != null) {
        _secondsRemaining = seconds;
        if (!widget.minimized) _startCountdown();
      }
      return;
    }

    if (oldWidget.minimized == widget.minimized) return;
    if (widget.minimized) {
      _stopCountdown();
    } else if (_hasCountdown) {
      _startCountdown();
    }
  }

  /// Tick once a second; play when the count reaches zero.
  ///
  /// [NextEpisodeOverlay.onPlay] only ever runs from the timer, never
  /// synchronously from here or from [didUpdateWidget]: restoring the card
  /// used to call it in the middle of the parent's rebuild, replacing the
  /// route while the framework was still building the old one.
  void _startCountdown() {
    _stopCountdown();
    _countdownTimer = Timer.periodic(_countdownTick, (timer) {
      if (!mounted || widget.minimized) return;
      if (_secondsRemaining > 0) setState(() => _secondsRemaining--);
      if (_secondsRemaining <= 0) {
        timer.cancel();
        _countdownTimer = null;
        widget.onPlay?.call();
      }
    });
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  @override
  void dispose() {
    _stopCountdown();
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
    color: AppColors.mediaBlack.withValues(alpha: _glassAlpha),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: AppColors.lineStrong, width: AppBorderWidth.thin),
  );

  Widget _buildMinimized() {
    final label = widget.episodeCode.isEmpty
        ? 'Show Up Next'
        : 'Show Up Next: ${widget.episodeCode}';
    return HubPressable(
      onTap: widget.onRestore,
      tooltip: label,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.sm,
          AppSpacing.xs,
        ),
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
              const SizedBox(width: AppSpacing.sm),
            ],
            if (widget.episodeCode.isNotEmpty)
              MonoLabel(
                widget.episodeCode,
                color: AppColors.fg1,
                uppercase: false,
                letterSpacing: 0.06,
              ),
            const SizedBox(width: AppSpacing.xxs),
            const Icon(
              Icons.keyboard_arrow_up_rounded,
              size: AppIconSize.sm,
              color: AppColors.fg2,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded() {
    return Container(
      width: _expandedWidth,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
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
                const SizedBox(width: AppSpacing.sm),
              ],
              if (widget.episodeCode.isNotEmpty) ...[
                MonoLabel(
                  widget.episodeCode,
                  color: AppColors.fg1,
                  uppercase: false,
                  letterSpacing: 0.06,
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.ui(
                    size: AppType.sizeCaption,
                    color: AppColors.fg,
                    weight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _OverlayButton(
                  label: 'Minimize',
                  onTap: widget.onMinimize,
                ),
              ),
              const SizedBox(width: _gap),
              Expanded(
                child: _OverlayButton(
                  label: 'Dismiss',
                  tooltip: 'Dismiss (Esc)',
                  onTap: widget.onDismiss,
                ),
              ),
              const SizedBox(width: _gap),
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
    this.tooltip,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool emphasized;

  static const double _verticalPadding = 7;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = !enabled
        ? AppColors.fg3
        : emphasized
        ? AppColors.onAccent
        : AppColors.fg1;
    final bg = !enabled
        ? AppColors.bgSurface.withAlpha(AppOpacity.semi)
        : emphasized
        ? AppColors.accent
        : AppColors.glassFill;

    final button = Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AppType.ui(
              size: AppType.sizeSmall,
              color: fg,
              weight: emphasized ? FontWeight.w600 : FontWeight.w500,
              height: 1.0,
            ),
          ),
        ),
      ),
    );
    final tip = tooltip;
    return tip == null ? button : Tooltip(message: tip, child: button);
  }
}
