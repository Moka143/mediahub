import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/local_media_file.dart';
import '../providers/auto_download_provider.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/opensubtitles_service.dart';
import '../utils/feedback_utils.dart';
import '../utils/formatters.dart';
import 'common/mediahub_chip.dart';
import 'common/mediahub_picker_sheet.dart';
import 'editorial/editorial.dart';
import 'streaming_status_indicator.dart';
import '../services/app_logger.dart';

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
    final theme = Theme.of(context);
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
          // Seek bar
          Row(
            children: [
              Text(
                Formatters.formatPlaybackDuration(position),
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
                      // Buffered track — lighter, behind the slider
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: bufferedRatio,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                      // Slider — transparent tracks so buffered layer shows through
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
                          value: hasDuration
                              ? (position.inMilliseconds /
                                        duration.inMilliseconds)
                                    .clamp(0.0, 1.0)
                              : 0.0,
                          onChanged: (value) {
                            if (hasDuration) {
                              final newPosition = Duration(
                                milliseconds: (value * duration.inMilliseconds)
                                    .round(),
                              );
                              playerService.seek(newPosition);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              Text(
                Formatters.formatPlaybackDuration(duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
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

              _VolumeControl(
                volume: volume,
                onVolumeChanged: (v) => playerService.setVolume(v),
              ),

              const Spacer(),

              _BottomTrackControls(
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

/// Volume control widget
class _VolumeControl extends StatefulWidget {
  final double volume;
  final ValueChanged<double> onVolumeChanged;

  const _VolumeControl({required this.volume, required this.onVolumeChanged});

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  bool _showSlider = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _showSlider = true),
      onExit: (_) => setState(() => _showSlider = false),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        padding: EdgeInsets.only(right: _showSlider ? AppSpacing.sm : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                widget.volume == 0
                    ? Icons.volume_off_rounded
                    : widget.volume < 50
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
                color: Colors.white,
              ),
              onPressed: () {
                widget.onVolumeChanged(widget.volume > 0 ? 0 : 100);
              },
            ),
            if (_showSlider)
              SizedBox(
                width: 100,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: widget.volume,
                    min: 0,
                    max: 100,
                    onChanged: widget.onVolumeChanged,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Subtitle track selector button with OpenSubtitles support
class _SubtitleButton extends ConsumerWidget {
  final double iconSize;

  const _SubtitleButton({this.iconSize = AppIconSize.lg});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitleTracksAsync = ref.watch(subtitleTracksProvider);
    final currentTrackAsync = ref.watch(currentSubtitleTrackProvider);
    final subtitleContext = ref.watch(subtitleContextProvider);
    final openSubtitlesAsync = ref.watch(availableSubtitlesProvider);
    final currentExternalSub = ref.watch(currentExternalSubtitleProvider);

    // Check if we have any subtitles available (embedded or OpenSubtitles)
    final hasEmbeddedTracks = subtitleTracksAsync.value?.isNotEmpty ?? false;
    final hasOpenSubtitles = openSubtitlesAsync.value?.isNotEmpty ?? false;
    final hasSubtitleContext = subtitleContext != null;
    final isLoadingOpenSubs =
        openSubtitlesAsync.isLoading && hasSubtitleContext;

    // Show button if we have embedded tracks, OpenSubtitles, or context to fetch
    if (!hasEmbeddedTracks && !hasOpenSubtitles && !hasSubtitleContext) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        IconButton(
          tooltip: 'Subtitles (C)',
          iconSize: iconSize,
          icon: Icon(
            currentExternalSub != null ||
                    (currentTrackAsync.value != null &&
                        currentTrackAsync.value != SubtitleTrack.no())
                ? Icons.closed_caption_rounded
                : Icons.closed_caption_off_rounded,
            color: Colors.white,
          ),
          onPressed: () => _showSubtitleMenu(
            context,
            subtitleTracksAsync.value ?? [],
            currentTrackAsync.value,
          ),
        ),
        if (isLoadingOpenSubs)
          Positioned(
            right: 4,
            top: 4,
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(
                  Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showSubtitleMenu(
    BuildContext context,
    List<SubtitleTrack> embeddedTracks,
    SubtitleTrack? currentEmbeddedTrack,
  ) {
    MediaHubPickerSheet.show(
      context: context,
      title: 'Subtitles',
      icon: Icons.closed_caption_rounded,
      child: Consumer(
        builder: (context, ref, _) {
          final openSubtitlesAsync = ref.watch(availableSubtitlesProvider);
          final currentExternalSub = ref.watch(currentExternalSubtitleProvider);
          final hasSubtitleContext = ref.watch(subtitleContextProvider) != null;
          final preferredLang = ref.watch(preferredSubtitleLanguageProvider);
          final openSubtitles = openSubtitlesAsync.value ?? [];
          final isLoadingOpenSubs =
              openSubtitlesAsync.isLoading && hasSubtitleContext;
          final groupedSubs = _groupSubtitlesByLanguage(
            openSubtitles,
            preferredLang: preferredLang,
          );
          final offSelected =
              currentEmbeddedTrack == SubtitleTrack.no() &&
              currentExternalSub == null;

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PickerSheetTile(
                icon: Icons.close_rounded,
                title: 'Off',
                selected: offSelected,
                onTap: () {
                  ref
                      .read(playerServiceProvider)
                      .setSubtitleTrack(SubtitleTrack.no());
                  ref.read(currentExternalSubtitleProvider.notifier).clear();
                  Navigator.pop(context);
                },
              ),
              if (embeddedTracks.isNotEmpty) ...[
                const PickerSheetSection(label: 'EMBEDDED'),
                for (final track in embeddedTracks)
                  PickerSheetTile(
                    icon: Icons.subtitles_rounded,
                    title: track.title ?? track.language ?? 'Track ${track.id}',
                    subtitle: track.title != null ? track.language : null,
                    selected:
                        currentEmbeddedTrack?.id == track.id &&
                        currentExternalSub == null,
                    onTap: () {
                      ref.read(playerServiceProvider).setSubtitleTrack(track);
                      ref
                          .read(currentExternalSubtitleProvider.notifier)
                          .clear();
                      Navigator.pop(context);
                    },
                  ),
              ],
              if (openSubtitles.isNotEmpty || isLoadingOpenSubs) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xxl,
                    AppSpacing.md,
                    AppSpacing.xxl,
                    AppSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      const MonoLabel(
                        'OPENSUBTITLES',
                        color: AppColors.fg3,
                        letterSpacing: 0.12,
                      ),
                      if (isLoadingOpenSubs) ...[
                        const SizedBox(width: AppSpacing.sm),
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(
                              AppColors.accent,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (openSubtitles.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.xxl,
                      0,
                      AppSpacing.xxl,
                      AppSpacing.md,
                    ),
                    child: Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.sm,
                      children: [
                        for (final entry in groupedSubs.entries)
                          MediaHubFilterChip(
                            label: entry.key,
                            selected:
                                currentExternalSub != null &&
                                entry.value.any(
                                  (s) => s.id == currentExternalSub.id,
                                ),
                            onTap: () {
                              final alreadyOn = entry.value.any(
                                (s) => s.id == currentExternalSub?.id,
                              );
                              if (alreadyOn) {
                                Navigator.pop(context);
                                return;
                              }
                              _loadExternalSubtitle(
                                ref,
                                entry.value.first,
                                context,
                              );
                            },
                          ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.xxl,
                      0,
                      AppSpacing.xxl,
                      AppSpacing.md,
                    ),
                    child: Text(
                      'Loading subtitles…',
                      style: AppType.ui(size: 12, color: AppColors.fg2),
                    ),
                  ),
              ],
              if (openSubtitles.isEmpty &&
                  !isLoadingOpenSubs &&
                  hasSubtitleContext)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.xxl,
                    AppSpacing.sm,
                    AppSpacing.xxl,
                    AppSpacing.md,
                  ),
                  child: Text(
                    'No subtitles found on OpenSubtitles',
                    style: AppType.ui(size: 12, color: AppColors.fg2),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// One entry per language. Preferred language, then English, then A–Z.
  /// Multiple OpenSubtitles files for the same language collapse to the first.
  Map<String, List<Subtitle>> _groupSubtitlesByLanguage(
    List<Subtitle> subtitles, {
    String? preferredLang,
  }) {
    final grouped = <String, List<Subtitle>>{};
    for (final sub in subtitles) {
      final lang = sub.langName ?? sub.lang;
      grouped.putIfAbsent(lang, () => []).add(sub);
    }

    int rank(String name) {
      final lower = name.toLowerCase();
      final preferred = preferredLang?.toLowerCase();
      if (preferred != null &&
          preferred.isNotEmpty &&
          (lower == preferred || lower.startsWith(preferred))) {
        return 0;
      }
      if (lower == 'english' || lower == 'en' || lower == 'eng') return 1;
      return 2;
    }

    final keys = grouped.keys.toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return {for (final key in keys) key: grouped[key]!};
  }

  Future<void> _loadExternalSubtitle(
    WidgetRef ref,
    Subtitle subtitle,
    BuildContext context,
  ) async {
    Navigator.pop(context);

    try {
      // Load the subtitle URL directly in media_kit
      await ref.read(playerServiceProvider).loadExternalSubtitle(subtitle.url);
      ref.read(currentExternalSubtitleProvider.notifier).set(subtitle);

      // Persist the selection so we can auto-load it next time.
      final ctx = ref.read(subtitleContextProvider);
      if (ctx != null) {
        final key = cacheKeyFromContext(ctx);
        if (key != null) {
          await ref
              .read(currentExternalSubtitleProvider.notifier)
              .persist(key, subtitle);
        }
      }
    } catch (e) {
      AppLog.e('[Subtitles] Failed to load subtitle: $e');
      if (context.mounted) {
        AppSnackBar.showError(
          context,
          message: '[Subtitles] Failed to load subtitle: ${e.toString()}',
        );
      }
    }
  }
}

/// Audio track selector button
class _AudioTrackButton extends ConsumerWidget {
  final double iconSize;

  const _AudioTrackButton({this.iconSize = AppIconSize.lg});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioTracksAsync = ref.watch(audioTracksProvider);
    final currentTrackAsync = ref.watch(currentAudioTrackProvider);

    return audioTracksAsync.when(
      data: (tracks) {
        if (tracks.length <= 1) return const SizedBox.shrink();

        return IconButton(
          tooltip: 'Audio track (A)',
          iconSize: iconSize,
          icon: const Icon(Icons.audiotrack_rounded, color: Colors.white),
          onPressed: () =>
              _showAudioMenu(context, ref, tracks, currentTrackAsync.value),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }

  void _showAudioMenu(
    BuildContext context,
    WidgetRef ref,
    List<AudioTrack> tracks,
    AudioTrack? currentTrack,
  ) {
    MediaHubPickerSheet.show(
      context: context,
      title: 'Audio',
      icon: Icons.audiotrack_rounded,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final track in tracks)
            PickerSheetTile(
              icon: Icons.audiotrack_rounded,
              title: track.title ?? track.language ?? 'Track ${track.id}',
              subtitle: track.language,
              selected: currentTrack?.id == track.id,
              onTap: () {
                ref.read(playerServiceProvider).setAudioTrack(track);
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }
}

/// Playback speed selector button
class _PlaybackSpeedButton extends ConsumerWidget {
  final double iconSize;

  const _PlaybackSpeedButton({this.iconSize = AppIconSize.lg});

  static const List<double> _speeds = [
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentRate = ref.watch(playbackRateProvider).value ?? 1.0;

    // Match the visual height of the surrounding IconButtons (kMinInteractiveDimension = 48)
    // so the cluster row stays uniform regardless of which control is hovered.
    return Tooltip(
      message: 'Playback speed (S)',
      child: InkWell(
        onTap: () => _showSpeedMenu(context, ref, currentRate),
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: Container(
          height: iconSize + AppSpacing.md,
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: currentRate != 1.0
                ? Colors.white.withValues(alpha: AppOpacity.medium / 255.0)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Text(
            '${currentRate}x',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: currentRate != 1.0
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  void _showSpeedMenu(BuildContext context, WidgetRef ref, double currentRate) {
    MediaHubPickerSheet.show(
      context: context,
      title: 'Playback speed',
      icon: Icons.speed_rounded,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final speed in _speeds)
            PickerSheetTile(
              icon: speed == 1.0
                  ? Icons.check_circle_rounded
                  : Icons.speed_rounded,
              title: speed == 1.0 ? 'Normal' : '${speed}x',
              selected: currentRate == speed,
              onTap: () {
                ref.read(playerServiceProvider).setPlaybackRate(speed);
                Navigator.pop(context);
              },
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom-bar track-control cluster
// ---------------------------------------------------------------------------

/// Soft-tinted pill grouping the track-selection controls in the bottom bar:
/// subtitles, audio, playback speed, and (for series) the per-show
/// "Continue Watching" toggle.
///
/// Replaces the trio that used to crowd the top bar — modern desktop players
/// (YouTube/Plex) anchor track-selection at the bottom near the seek bar.
class _BottomTrackControls extends StatelessWidget {
  final int? showId;

  /// Sub-mobile width — shrink icons so the cluster doesn't crowd the seek
  /// row. The functional controls are unchanged.
  final bool isCompact;

  /// Forwarded to `_ContinueWatchingToggle` so the player can kick off
  /// the auto-download immediately when the user opts in.
  final VoidCallback? onContinueWatchingActivated;

  final NextEpisodePrefetch? nextEpisodePrefetch;

  const _BottomTrackControls({
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
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.xs),
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
          _SubtitleButton(iconSize: iconSize),
          _AudioTrackButton(iconSize: iconSize),
          _PlaybackSpeedButton(iconSize: iconSize),
          if (showId != null)
            _ContinueWatchingToggle(
              showId: showId!,
              iconSize: iconSize,
              onActivated: onContinueWatchingActivated,
            ),
          _NextEpisodePrefetchIndicator(
            prefetch: nextEpisodePrefetch,
            compact: isCompact,
          ),
        ],
      ),
    );
  }
}

/// Thin spinner (and optional episode code) that sits beside the Continue
/// Watching pill while the next episode prefetches. Replaces the old card
/// that sat on top of the video.
class _NextEpisodePrefetchIndicator extends StatelessWidget {
  const _NextEpisodePrefetchIndicator({
    required this.prefetch,
    required this.compact,
  });

  final NextEpisodePrefetch? prefetch;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final data = prefetch;
    final spinnerSize = compact ? 12.0 : 14.0;

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
                          size: 9,
                          color: Colors.white70,
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
                          size: 9,
                          color: Colors.white70,
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
      case StreamingStatus.found:
        return CircularProgressIndicator(
          strokeWidth: 1.6,
          color: Colors.white.withValues(alpha: 0.85),
          backgroundColor: Colors.white.withValues(alpha: 0.2),
        );
      case StreamingStatus.buffering:
        return CircularProgressIndicator(
          strokeWidth: 1.6,
          value: data.progress,
          color: Colors.white.withValues(alpha: 0.85),
          backgroundColor: Colors.white.withValues(alpha: 0.2),
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
      case StreamingStatus.found:
        return '$prefix · finding source';
      case StreamingStatus.buffering:
        final parts = <String>[prefix];
        if (data.progress != null && data.progress! > 0) {
          parts.add(Formatters.formatProgress(data.progress!));
        }
        if (data.downloadRateBytesPerSec > 0) {
          parts.add(Formatters.formatSpeed(data.downloadRateBytesPerSec));
        } else if (data.progress == null || data.progress! <= 0) {
          parts.add('buffering');
        }
        return parts.join(' · ');
      case StreamingStatus.ready:
        return '$prefix · ready';
      case StreamingStatus.error:
        return data.message ?? '$prefix · failed';
    }
  }
}

/// Per-show "Continue Watching" pill in the bottom bar.
///
/// Three states:
///   • **Auto** (default) — Up Next card near the end; you confirm. Does
///     not cover the player. Follows Settings → Auto-Download for prefetch.
///   • **On** — prefetch the next episode at the watch threshold (default
///     70%, set in Settings) so it is ready, then play it only when this
///     episode actually ends.
///   • **Off** — never prefetch, never auto-play this show.
///
/// Tap cycles `Auto → On → Off → Auto`. Persisted in [AutoDownloadState]
/// via `setShowAutoDownloadOverride`. Turning On mid-episode only starts
/// the prefetch if playback is already past the threshold.
class _ContinueWatchingToggle extends ConsumerWidget {
  final int showId;
  final double iconSize;

  /// Fired only on the `null → true` and `false → true` transitions.
  /// If playback is already past the auto-download threshold, the player
  /// prefetches the next episode in the background without switching to it.
  final VoidCallback? onActivated;

  const _ContinueWatchingToggle({
    required this.showId,
    this.iconSize = AppIconSize.lg,
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
    final String label;
    final Color bgColor;
    final Color borderColor;
    final Color fgColor;
    final String tooltip;

    if (override == true) {
      icon = Icons.playlist_play_rounded;
      label = 'On';
      bgColor = scheme.primaryContainer;
      borderColor = Colors.transparent;
      fgColor = scheme.onPrimaryContainer;
      tooltip =
          'On — prefetch at ${((state.progressThreshold) * 100).toInt()}%, play when this episode ends';
    } else if (override == false) {
      icon = Icons.playlist_remove_rounded;
      label = 'Off';
      bgColor = scheme.surfaceContainerHigh;
      borderColor = Colors.transparent;
      fgColor = scheme.onSurfaceVariant;
      tooltip = 'Off — do not prefetch the next episode';
    } else {
      icon = Icons.playlist_play_rounded;
      label = 'Auto';
      bgColor = Colors.transparent;
      borderColor = scheme.outlineVariant.withValues(
        alpha: AppOpacity.semi / 255.0,
      );
      fgColor = scheme.onSurfaceVariant;
      tooltip = 'Auto — Up Next card near the end, player stays usable';
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () {
          // Auto → On → Off → Auto
          final next = override == null
              ? true
              : override == true
              ? false
              : null;
          AppLog.d(
            '[ContinueWatching] tapped: showId=$showId override=$override → ${next ?? "auto"}',
          );
          ref
              .read(autoDownloadProvider.notifier)
              .setShowAutoDownloadOverride(showId, next);
          // Notify the player when we just opted in, so it can kick off
          // the next-episode auto-download immediately rather than waiting
          // for the progress threshold.
          if (next == true) {
            onActivated?.call();
          }
        },
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: AnimatedContainer(
          duration: AppDuration.normal,
          curve: Curves.easeOutCubic,
          height: iconSize + AppSpacing.md,
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
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
                  key: ValueKey(label),
                  size: iconSize,
                  color: fgColor,
                ),
              ),
              SizedBox(width: AppSpacing.xs),
              Text(
                label,
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
