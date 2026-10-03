import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../models/streaming_status.dart';
import '../../providers/auto_download_provider.dart';
import '../../services/app_logger.dart';
import '../../utils/formatters.dart';
import '../editorial/editorial.dart';
import 'track_buttons.dart';

/// Soft-tinted pill grouping the track-selection controls in the bottom bar:
/// subtitles, audio, playback speed, and (for series) the per-show
/// Next episode mode.
///
/// Replaces the trio that used to crowd the top bar — modern desktop players
/// (YouTube/Plex) anchor track-selection at the bottom near the seek bar.
class BottomTrackControls extends StatelessWidget {
  final int? showId;

  /// Sub-mobile width — shrink icons so the cluster doesn't crowd the seek
  /// row. The functional controls are unchanged.
  final bool isCompact;

  /// Forwarded to [NextEpisodeModeToggle] so the player can fetch the next
  /// episode immediately when the user switches it On.
  final VoidCallback? onContinueWatchingActivated;

  final NextEpisodePrefetch? nextEpisodePrefetch;

  const BottomTrackControls({
    super.key,
    required this.showId,
    required this.isCompact,
    this.onContinueWatchingActivated,
    this.nextEpisodePrefetch,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconSize = isCompact ? AppIconSize.md : AppIconSize.lg;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(
          alpha: AppOpacity.medium / 255.0,
        ),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(
          color: scheme.outlineVariant.withValues(
            alpha: AppOpacity.light / 255.0,
          ),
          width: AppBorderWidth.thin,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SubtitleButton(iconSize: iconSize),
          AudioTrackButton(iconSize: iconSize),
          PlaybackSpeedButton(iconSize: iconSize),
          if (showId != null)
            NextEpisodeModeToggle(
              showId: showId!,
              iconSize: iconSize,
              compact: isCompact,
              onActivated: onContinueWatchingActivated,
            ),
          NextEpisodePrefetchIndicator(
            prefetch: nextEpisodePrefetch,
            compact: isCompact,
          ),
        ],
      ),
    );
  }
}

/// Thin spinner (and optional episode code) that sits beside the Next
/// episode pill while the next episode is fetched in the background.
/// Replaces the old card that sat on top of the video.
class NextEpisodePrefetchIndicator extends StatelessWidget {
  const NextEpisodePrefetchIndicator({
    super.key,
    required this.prefetch,
    required this.compact,
  });

  final NextEpisodePrefetch? prefetch;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final data = prefetch;
    final spinnerSize = compact ? AppIconSize.xs - 2 : AppIconSize.xs;

    return AnimatedSize(
      duration: AppDuration.fast,
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: data == null
          ? const SizedBox.shrink()
          : Tooltip(
              message: _tooltip(data),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.xs,
                  right: AppSpacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: spinnerSize,
                      height: spinnerSize,
                      child: _glyph(data, spinnerSize),
                    ),
                    if (!compact) ...[
                      if (data.episodeCode != null) ...[
                        const SizedBox(width: AppSpacing.xs),
                        MonoLabel(
                          data.episodeCode!,
                          color: AppColors.onMediaMuted,
                          letterSpacing: 0.08,
                        ),
                      ],
                      if (data.isBusy &&
                          data.progress != null &&
                          data.progress! > 0) ...[
                        const SizedBox(width: AppSpacing.xs),
                        MonoLabel(
                          Formatters.formatProgress(
                            data.progress!,
                            decimals: 0,
                          ),
                          color: AppColors.onMediaMuted,
                          letterSpacing: 0.04,
                          uppercase: false,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _glyph(NextEpisodePrefetch data, double size) {
    switch (data.status) {
      case StreamingStatus.searching:
        return CircularProgressIndicator(
          strokeWidth: 1.6,
          color: AppColors.onMedia.withValues(alpha: 0.85),
          backgroundColor: AppColors.onMedia.withAlpha(AppOpacity.medium),
        );
      case StreamingStatus.buffering:
        return CircularProgressIndicator(
          strokeWidth: 1.6,
          value: data.progress,
          color: AppColors.onMedia.withValues(alpha: 0.85),
          backgroundColor: AppColors.onMedia.withAlpha(AppOpacity.medium),
        );
      case StreamingStatus.ready:
        return Icon(Icons.check_rounded, size: size, color: AppColors.ok);
      case StreamingStatus.error:
        return Icon(
          Icons.error_outline_rounded,
          size: size,
          color: AppColors.err,
        );
    }
  }

  String _tooltip(NextEpisodePrefetch data) {
    final prefix = data.episodeCode ?? 'Next episode';
    switch (data.status) {
      case StreamingStatus.searching:
        return '$prefix · finding a source';
      case StreamingStatus.buffering:
        final message = data.message;
        if (message != null) return '$prefix · $message';
        final parts = <String>[prefix];
        if (data.progress != null && data.progress! > 0) {
          parts.add(Formatters.formatProgress(data.progress!));
        }
        if (data.downloadRateBytesPerSec > 0) {
          parts.add(Formatters.formatSpeed(data.downloadRateBytesPerSec));
        } else if (data.progress == null || data.progress! <= 0) {
          parts.add('getting ready');
        }
        return parts.join(' · ');
      case StreamingStatus.ready:
        return '$prefix · ready';
      case StreamingStatus.error:
        return data.message ?? "$prefix · couldn't start";
    }
  }
}

/// Per-show "Next episode" pill in the bottom bar.
///
/// Three states:
///   • **Auto** (default) — Up Next card near the end; you confirm. Does
///     not cover the player. Follows Settings → Auto-Download for fetching
///     ahead.
///   • **On** — fetch the next episode at the watch threshold (default 70%,
///     set in Settings) so it is ready, then play it only when this episode
///     actually ends.
///   • **Off** — never fetch ahead, never auto-play this show.
///
/// Click cycles `Auto → On → Off → Auto`. Persisted in [AutoDownloadState]
/// via `setShowAutoDownloadOverride`. Turning On mid-episode only starts the
/// fetch if playback is already past the threshold.
///
/// It used to read "Continue Watching", the name of the Home row of
/// half-watched titles — two unrelated things under one label.
class NextEpisodeModeToggle extends ConsumerWidget {
  final int showId;
  final double iconSize;

  /// Narrow window: show only the mode, not "Next episode:".
  final bool compact;

  /// Fired only on the `null → true` and `false → true` transitions.
  /// If playback is already past the auto-download threshold, the player
  /// fetches the next episode in the background without switching to it.
  final VoidCallback? onActivated;

  const NextEpisodeModeToggle({
    super.key,
    required this.showId,
    this.iconSize = AppIconSize.lg,
    this.compact = false,
    this.onActivated,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = ref.watch(autoDownloadProvider);
    final override = state.showAutoDownloadOverrides[showId];

    // Visual state mapping
    final IconData icon;
    final String mode;
    final Color bgColor;
    final Color borderColor;
    final Color fgColor;
    final String tooltip;

    if (override == true) {
      icon = Icons.playlist_play_rounded;
      mode = 'On';
      bgColor = scheme.primaryContainer;
      borderColor = Colors.transparent;
      fgColor = scheme.onPrimaryContainer;
      tooltip =
          'Next episode: On — fetch it at '
          '${(state.progressThreshold * 100).toInt()}% and play it when '
          'this one ends';
    } else if (override == false) {
      icon = Icons.playlist_remove_rounded;
      mode = 'Off';
      bgColor = scheme.surfaceContainerHigh;
      borderColor = Colors.transparent;
      fgColor = scheme.onSurfaceVariant;
      tooltip = "Next episode: Off — don't fetch or play the next episode";
    } else {
      icon = Icons.playlist_play_rounded;
      mode = 'Auto';
      bgColor = Colors.transparent;
      borderColor = scheme.outlineVariant.withValues(
        alpha: AppOpacity.semi / 255.0,
      );
      fgColor = scheme.onSurfaceVariant;
      tooltip = 'Next episode: Auto — offer it near the end';
    }

    return Tooltip(
      message: '$tooltip. Click to change.',
      child: InkWell(
        onTap: () {
          // Auto → On → Off → Auto
          final next = override == null
              ? true
              : override == true
              ? false
              : null;
          AppLog.d(
            '[NextEpisodeMode] clicked: showId=$showId override=$override → '
            '${next ?? "auto"}',
          );
          unawaited(
            ref
                .read(autoDownloadProvider.notifier)
                .setShowAutoDownloadOverride(showId, next),
          );
          // Notify the player when we just opted in, so it can fetch the
          // next episode immediately rather than waiting for the progress
          // threshold.
          if (next == true) {
            onActivated?.call();
          }
        },
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: AnimatedContainer(
          duration: AppDuration.normal,
          curve: Curves.easeOutCubic,
          height: iconSize + AppSpacing.md,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: borderColor, width: AppBorderWidth.thin),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: AppDuration.fast,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Icon(
                  icon,
                  key: ValueKey(mode),
                  size: iconSize,
                  color: fgColor,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                compact ? mode : 'Next episode: $mode',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: fgColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
