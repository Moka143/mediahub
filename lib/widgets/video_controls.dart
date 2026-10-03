import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/local_media_file.dart';
import '../models/streaming_status.dart';
import '../providers/player_provider.dart';
import '../services/playback_health_monitor.dart';
import '../utils/media_names.dart';
import 'player/bottom_track_controls.dart';
import 'player/seek_bar.dart';
import 'player/volume_control.dart';

/// Custom video controls overlay
///
/// Watches nothing that changes during playback itself: the position lives
/// in [PlayerSeekBar] and the volume in its own slot, so a position tick —
/// about one per frame — rebuilds the seek row and not every control here.
class VideoControlsOverlay extends StatelessWidget {
  final LocalMediaFile file;
  final bool isPlaying;
  final bool isFullscreen;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekForward;
  final VoidCallback onSeekBackward;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onClose;
  final VoidCallback onShowShortcuts;

  /// When set (streaming mode), this overrides mpv's demuxer-cache reading
  /// for the "buffered" seek-bar track. mpv's cache reflects what the demuxer
  /// has read, which from a sparse torrent file may include zero-region
  /// over-reads — useless as a seek hint. The actual file-download fraction
  /// (0.0–1.0) is what tells the user how far they can safely seek.
  final double? streamingDownloadedRatio;

  /// Where the downloaded bytes actually are, from the torrent's piece map.
  /// Takes precedence over [streamingDownloadedRatio] when non-empty — see
  /// [BufferedSpan] for why a single fraction is not enough.
  final List<BufferedSpan> bufferedSpans;

  /// TMDB show id for a series episode. Drives the per-show Next episode
  /// pill in the bottom bar. `null` for movies or untagged content — the
  /// pill is hidden.
  final int? showId;

  /// Fired when the Next episode pill switches to On. If playback is already
  /// past the auto-download threshold, the player fetches the next episode
  /// in the background. The current episode keeps playing.
  final VoidCallback? onContinueWatchingActivated;

  /// Background next-episode prefetch. Renders as a spinner beside the
  /// Next episode pill — never as a card over the video.
  final NextEpisodePrefetch? nextEpisodePrefetch;

  const VideoControlsOverlay({
    super.key,
    required this.file,
    required this.isPlaying,
    required this.isFullscreen,
    required this.onPlayPause,
    required this.onSeekForward,
    required this.onSeekBackward,
    required this.onToggleFullscreen,
    required this.onClose,
    required this.onShowShortcuts,
    this.streamingDownloadedRatio,
    this.bufferedSpans = const [],
    this.showId,
    this.onContinueWatchingActivated,
    this.nextEpisodePrefetch,
  });

  static const double _playButtonSize = 40;

  /// The show for an episode; otherwise the file's name without its release
  /// tags, or the raw name when nothing recognisable is left.
  String get _title {
    final show = file.showName;
    if (show != null && show.isNotEmpty) return show;
    final cleaned = cleanMediaTitle(file.fileName);
    return cleaned.isEmpty ? file.fileName : cleaned;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.mediaBlack.withValues(alpha: 0.7),
            Colors.transparent,
            Colors.transparent,
            AppColors.mediaBlack.withValues(alpha: 0.7),
          ],
          stops: const [0.0, 0.2, 0.8, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),

            // Deliberately empty. Transport controls live in the bottom bar;
            // keeping the centre of the frame clear means the controls
            // overlay never covers the picture. Double-click anywhere
            // toggles playback (see VideoPlayerScreen).
            const Expanded(child: SizedBox.shrink()),

            _buildBottomControls(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: AppColors.mediaBlack.withAlpha(AppOpacity.semi),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              tooltip: 'Back (Esc)',
              icon: const Icon(
                Icons.arrow_back_rounded,
                color: AppColors.onMedia,
              ),
              onPressed: onClose,
            ),
          ),
          const SizedBox(width: AppSpacing.md),

          // Title
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (file.episodeCode != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      '${file.episodeCode!} · NOW PLAYING',
                      style: AppType.mono(
                        size: AppType.sizeLabel,
                        color: AppColors.accent,
                        weight: FontWeight.w500,
                        letterSpacing: 0.14,
                      ),
                    ),
                  ),
                Text(
                  _title,
                  style: AppType.serif(
                    size: AppType.sizeTitle,
                    color: AppColors.onMedia,
                    height: 1.0,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // Track-selection / playback-speed / next-episode all live in the
          // bottom bar (next to the seek controls). The top bar is
          // intentionally minimal: back, title, keyboard shortcuts.
          IconButton(
            icon: const Icon(Icons.keyboard_rounded, color: AppColors.onMedia),
            tooltip: 'Keyboard shortcuts (?)',
            onPressed: onShowShortcuts,
          ),
        ],
      ),
    );
  }

  /// Transport cluster for the bottom bar: rewind, play/pause, forward.
  ///
  /// These used to sit as a large floating cluster in the middle of the frame,
  /// directly over the picture. Bottom-left is where every desktop player puts
  /// them, and it leaves the video unobstructed.
  Widget _buildTransportControls() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(
            Icons.replay_10_rounded,
            size: AppIconSize.md,
            color: AppColors.onMedia,
          ),
          onPressed: onSeekBackward,
          tooltip: 'Back 10 seconds (←)',
        ),

        // Play/Pause — the primary action, so it carries a soft fill to lift
        // it above the flanking seek buttons without introducing a new hue.
        Container(
          width: _playButtonSize,
          height: _playButtonSize,
          decoration: BoxDecoration(
            color: AppColors.glassBorder,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: AppIconSize.md,
              color: AppColors.onMedia,
            ),
            onPressed: onPlayPause,
            tooltip: isPlaying ? 'Pause (Space)' : 'Play (Space)',
          ),
        ),

        IconButton(
          icon: const Icon(
            Icons.forward_10_rounded,
            size: AppIconSize.md,
            color: AppColors.onMedia,
          ),
          onPressed: onSeekForward,
          tooltip: 'Forward 10 seconds (→)',
        ),
      ],
    );
  }

  Widget _buildBottomControls(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.screenPadding,
        right: AppSpacing.screenPadding,
        bottom: AppSpacing.lg,
      ),
      child: Column(
        children: [
          PlayerSeekBar(
            streamingDownloadedRatio: streamingDownloadedRatio,
            bufferedSpans: bufferedSpans,
          ),
          const SizedBox(height: AppSpacing.sm),

          // Bottom buttons — three-cluster layout:
          //   [⟲ ▶ ⟳ | Volume]  ──  [CC | Audio | Speed | Next]  ──  [Full screen]
          // Mirrors modern desktop players (YouTube/Plex). The track-controls
          // cluster is wrapped in a soft-tinted pill so it reads as one unit.
          Row(
            children: [
              _buildTransportControls(),

              const SizedBox(width: AppSpacing.xs),

              const _PlayerVolume(),

              const Spacer(),

              BottomTrackControls(
                showId: showId,
                isCompact:
                    MediaQuery.sizeOf(context).width < AppBreakpoints.mobile,
                onContinueWatchingActivated: onContinueWatchingActivated,
                nextEpisodePrefetch: nextEpisodePrefetch,
              ),

              const SizedBox(width: AppSpacing.sm),

              Container(
                decoration: BoxDecoration(
                  color: AppColors.onMedia.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: IconButton(
                  tooltip: isFullscreen
                      ? 'Leave full screen (F)'
                      : 'Full screen (F)',
                  icon: Icon(
                    isFullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: AppColors.onMedia,
                  ),
                  onPressed: onToggleFullscreen,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// [VolumeControl] wired to the player. Its own consumer so a volume change
/// rebuilds this and nothing else.
class _PlayerVolume extends ConsumerWidget {
  const _PlayerVolume();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(volumeProvider).value ?? 100.0;
    final playerService = ref.read(playerServiceProvider);
    return VolumeControl(
      volume: volume,
      onVolumeChanged: (v) => unawaited(playerService.setVolume(v)),
      onToggleMute: () => unawaited(playerService.toggleMute()),
    );
  }
}
