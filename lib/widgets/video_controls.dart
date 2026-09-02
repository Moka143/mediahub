import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/local_media_file.dart';
import '../providers/player_provider.dart';
import '../services/playback_health_monitor.dart';
import 'player/bottom_track_controls.dart';
import 'player/seek_bar.dart';
import 'player/volume_control.dart';
import 'streaming_status_indicator.dart';

/// Custom video controls overlay
class VideoControlsOverlay extends ConsumerWidget {
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

  /// TMDB show id for a series episode. Drives the per-show
  /// "Continue Watching" toggle in the bottom bar. `null` for movies or
  /// untagged content — toggle is hidden.
  final int? showId;

  /// Fired when the Continue Watching toggle transitions to explicit-On.
  /// If playback is already past the auto-download threshold, the player
  /// prefetches the next episode in the background. The current episode
  /// keeps playing.
  final VoidCallback? onContinueWatchingActivated;

  /// Background next-episode prefetch. Renders as a spinner beside the
  /// Continue Watching pill — never as a card over the video.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final duration = ref.watch(playbackDurationProvider).value ?? Duration.zero;
    final buffered = ref.watch(playbackBufferProvider).value ?? Duration.zero;
    final volume = ref.watch(volumeProvider).value ?? 100.0;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.7),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.7),
          ],
          stops: const [0.0, 0.2, 0.8, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar
            _buildTopBar(context, ref),

            // Deliberately empty. Transport controls live in the bottom bar;
            // keeping the centre of the frame clear means the controls
            // overlay never covers the picture. Double-click anywhere
            // toggles playback (see VideoPlayerScreen).
            const Expanded(child: SizedBox.shrink()),

            // Bottom controls
            _buildBottomControls(
              context,
              ref,
              position,
              duration,
              buffered,
              volume,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          // Back button
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
              onPressed: onClose,
            ),
          ),
          SizedBox(width: AppSpacing.md),

          // Title
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (file.episodeCode != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${file.episodeCode!} · NOW PLAYING',
                      style: AppType.mono(
                        size: 10,
                        color: AppColors.accent,
                        weight: FontWeight.w500,
                        letterSpacing: 0.14,
                      ),
                    ),
                  ),
                Text(
                  file.showName ?? 'Video',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontStyle: FontStyle.italic,
                    fontFamily: 'serif',
                    height: 1.0,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),

          // Track-selection / playback-speed / continue-watching all live
          // in the bottom bar now (next to the seek controls). Top bar is
          // intentionally minimal: back, title, keyboard-shortcuts.
          IconButton(
            icon: const Icon(Icons.keyboard_rounded, color: Colors.white),
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
  Widget _buildTransportControls(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: 'Rewind 10 seconds',
          button: true,
          child: IconButton(
            icon: const Icon(
              Icons.replay_10_rounded,
              size: AppIconSize.md,
              color: Colors.white,
            ),
            onPressed: onSeekBackward,
            tooltip: 'Rewind 10s (←)',
          ),
        ),

        // Play/Pause — the primary action, so it carries a soft fill to lift
        // it above the flanking seek buttons without introducing a new hue.
        Semantics(
          label: isPlaying ? 'Pause video' : 'Play video',
          button: true,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: AppIconSize.md,
                color: Colors.white,
              ),
              onPressed: onPlayPause,
              tooltip: isPlaying ? 'Pause (space)' : 'Play (space)',
            ),
          ),
        ),

        Semantics(
          label: 'Fast forward 10 seconds',
          button: true,
          child: IconButton(
            icon: const Icon(
              Icons.forward_10_rounded,
              size: AppIconSize.md,
              color: Colors.white,
            ),
            onPressed: onSeekForward,
            tooltip: 'Forward 10s (→)',
          ),
        ),
      ],
    );
  }

  Widget _buildBottomControls(
    BuildContext context,
    WidgetRef ref,
    Duration position,
    Duration duration,
    Duration buffered,
    double volume,
  ) {
    final playerService = ref.read(playerServiceProvider);
    final hasDuration = duration.inMilliseconds > 0;
    // Streaming mode: prefer the actual download-on-disk ratio over mpv's
    // demuxer cache, which can over-report when reading from sparse regions.
    final bufferedRatio = streamingDownloadedRatio != null
        ? streamingDownloadedRatio!.clamp(0.0, 1.0)
        : (hasDuration
              ? (buffered.inMilliseconds / duration.inMilliseconds).clamp(
                  0.0,
                  1.0,
                )
              : 0.0);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.screenPadding,
        0,
        AppSpacing.screenPadding,
        AppSpacing.lg,
      ),
      child: Column(
        children: [
          SeekBar(
            position: position,
            duration: duration,
            bufferedRatio: bufferedRatio,
            bufferedSpans: bufferedSpans,
          ),
          SizedBox(height: AppSpacing.sm),

          // Bottom buttons — three-cluster layout:
          //   [⟲ ▶ ⟳ | Volume]  ──  [CC | Audio | Speed | CW]  ──  [Fullscreen]
          // Mirrors modern desktop players (YouTube/Plex). The track-controls
          // cluster is wrapped in a soft-tinted pill so it reads as one unit.
          Row(
            children: [
              _buildTransportControls(context),

              SizedBox(width: AppSpacing.xs),

              VolumeControl(
                volume: volume,
                onVolumeChanged: (v) => playerService.setVolume(v),
              ),

              const Spacer(),

              BottomTrackControls(
                showId: showId,
                isCompact:
                    MediaQuery.of(context).size.width < AppBreakpoints.mobile,
                onContinueWatchingActivated: onContinueWatchingActivated,
                nextEpisodePrefetch: nextEpisodePrefetch,
              ),

              SizedBox(width: AppSpacing.sm),

              // Fullscreen toggle
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: IconButton(
                  icon: Icon(
                    isFullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: Colors.white,
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
