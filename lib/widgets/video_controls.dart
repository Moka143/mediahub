import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../providers/auto_download_provider.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/opensubtitles_service.dart';
import '../utils/feedback_utils.dart';

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
  /// The player uses this to kick off the next-episode auto-download
  /// immediately rather than waiting for the progress threshold.
  final VoidCallback? onContinueWatchingActivated;

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

            // Middle spacer with center play button
            Expanded(child: Center(child: _buildCenterControls(context))),

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
                Text(
                  file.showName ?? 'Video',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (file.episodeCode != null)
                  Text(
                    file.episodeCode!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
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

  Widget _buildCenterControls(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Seek backward
        Semantics(
          label: 'Rewind 10 seconds',
          button: true,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: Icon(
                Icons.replay_10_rounded,
                size: AppIconSize.xl,
                color: Colors.white,
              ),
              onPressed: onSeekBackward,
              tooltip: 'Rewind 10s',
            ),
          ),
        ),
        SizedBox(width: AppSpacing.xl),

        // Play/Pause
        Semantics(
          label: isPlaying ? 'Pause video' : 'Play video',
          button: true,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: IconButton(
              icon: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: AppIconSize.xxxl,
                color: Colors.white,
              ),
              onPressed: onPlayPause,
              tooltip: isPlaying ? 'Pause' : 'Play',
            ),
          ),
        ),
        SizedBox(width: AppSpacing.xl),

        // Seek forward
        Semantics(
          label: 'Fast forward 10 seconds',
          button: true,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: Icon(
                Icons.forward_10_rounded,
                size: AppIconSize.xl,
                color: Colors.white,
              ),
              onPressed: onSeekForward,
              tooltip: 'Forward 10s',
            ),
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
                _formatDuration(position),
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
                _formatDuration(duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),

          // Bottom buttons — three-cluster layout:
          //   [Volume]  ────  [CC | Audio | Speed | ContinueWatching]  ────  [Fullscreen]
          // Mirrors modern desktop players (YouTube/Plex). The track-controls
          // cluster is wrapped in a soft-tinted pill so it reads as one unit.
          Row(
            children: [
              _VolumeControl(
                volume: volume,
                onVolumeChanged: (v) => playerService.setVolume(v),
              ),

              const Spacer(),

              _BottomTrackControls(
                showId: showId,
                isCompact: MediaQuery.of(context).size.width <
                    AppBreakpoints.mobile,
                onContinueWatchingActivated: onContinueWatchingActivated,
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

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
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
            ref,
            subtitleTracksAsync.value ?? [],
            currentTrackAsync.value,
            openSubtitlesAsync.value ?? [],
            currentExternalSub,
            isLoadingOpenSubs,
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
    WidgetRef ref,
    List<SubtitleTrack> embeddedTracks,
    SubtitleTrack? currentEmbeddedTrack,
    List<Subtitle> openSubtitles,
    Subtitle? currentExternalSub,
    bool isLoadingOpenSubs,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Consumer(
          builder: (context, ref, _) {
            final theme = Theme.of(context);
            final groupedSubs = _groupSubtitlesByLanguage(openSubtitles);

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Padding(
                        padding: EdgeInsets.all(AppSpacing.lg),
                        child: Row(
                          children: [
                            Icon(
                              Icons.closed_caption_rounded,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              'Subtitles',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Off option
                      ListTile(
                        leading: Icon(
                          Icons.close_rounded,
                          color:
                              (currentEmbeddedTrack == SubtitleTrack.no() &&
                                  currentExternalSub == null)
                              ? theme.colorScheme.primary
                              : null,
                        ),
                        title: const Text('Off'),
                        selected:
                            currentEmbeddedTrack == SubtitleTrack.no() &&
                            currentExternalSub == null,
                        onTap: () {
                          ref
                              .read(playerServiceProvider)
                              .setSubtitleTrack(SubtitleTrack.no());
                          ref
                              .read(currentExternalSubtitleProvider.notifier)
                              .clear();
                          Navigator.pop(context);
                        },
                      ),

                      // Embedded tracks section
                      if (embeddedTracks.isNotEmpty) ...[
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.md,
                            AppSpacing.lg,
                            AppSpacing.xs,
                          ),
                          child: Text(
                            'Embedded Subtitles',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ...embeddedTracks.map(
                          (track) => ListTile(
                            leading: Icon(
                              Icons.subtitles_rounded,
                              color:
                                  currentEmbeddedTrack?.id == track.id &&
                                      currentExternalSub == null
                                  ? theme.colorScheme.primary
                                  : null,
                            ),
                            title: Text(
                              track.title ??
                                  track.language ??
                                  'Track ${track.id}',
                            ),
                            subtitle: track.language != null
                                ? Text(track.language!)
                                : null,
                            selected:
                                currentEmbeddedTrack?.id == track.id &&
                                currentExternalSub == null,
                            onTap: () {
                              ref
                                  .read(playerServiceProvider)
                                  .setSubtitleTrack(track);
                              ref
                                  .read(
                                    currentExternalSubtitleProvider.notifier,
                                  )
                                  .clear();
                              Navigator.pop(context);
                            },
                          ),
                        ),
                      ],

                      // OpenSubtitles section
                      if (openSubtitles.isNotEmpty || isLoadingOpenSubs) ...[
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.md,
                            AppSpacing.lg,
                            AppSpacing.xs,
                          ),
                          child: Row(
                            children: [
                              Text(
                                'OpenSubtitles',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (isLoadingOpenSubs) ...[
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation(
                                      theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (openSubtitles.isNotEmpty)
                          ...groupedSubs.entries.map((entry) {
                            final langName = entry.key;
                            final subs = entry.value;
                            final firstSub = subs.first;

                            // If only one subtitle for this language, show directly
                            if (subs.length == 1) {
                              return ListTile(
                                leading: Text(
                                  firstSub.flagEmoji,
                                  style: const TextStyle(fontSize: 20),
                                ),
                                title: Text(langName),
                                selected: currentExternalSub?.id == firstSub.id,
                                onTap: () => _loadExternalSubtitle(
                                  ref,
                                  firstSub,
                                  context,
                                ),
                              );
                            }

                            // If multiple subtitles for this language, use expansion tile
                            return ExpansionTile(
                              leading: Text(
                                firstSub.flagEmoji,
                                style: const TextStyle(fontSize: 20),
                              ),
                              title: Text('$langName (${subs.length})'),
                              children: subs.asMap().entries.map((subEntry) {
                                final index = subEntry.key;
                                final sub = subEntry.value;
                                return ListTile(
                                  leading: const SizedBox(width: 20),
                                  title: Text('$langName #${index + 1}'),
                                  selected: currentExternalSub?.id == sub.id,
                                  onTap: () =>
                                      _loadExternalSubtitle(ref, sub, context),
                                );
                              }).toList(),
                            );
                          }),
                        if (openSubtitles.isEmpty && isLoadingOpenSubs)
                          Padding(
                            padding: EdgeInsets.all(AppSpacing.lg),
                            child: Center(
                              child: Text(
                                'Loading subtitles...',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                      ],

                      // No OpenSubtitles available message
                      if (openSubtitles.isEmpty &&
                          !isLoadingOpenSubs &&
                          ref.read(subtitleContextProvider) != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            AppSpacing.lg,
                            AppSpacing.md,
                            AppSpacing.lg,
                            AppSpacing.lg,
                          ),
                          child: Text(
                            'No subtitles found on OpenSubtitles',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),

                      const SizedBox(height: AppSpacing.md),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Map<String, List<Subtitle>> _groupSubtitlesByLanguage(
    List<Subtitle> subtitles,
  ) {
    final Map<String, List<Subtitle>> grouped = {};
    for (final sub in subtitles) {
      final lang = sub.langName ?? sub.lang;
      grouped.putIfAbsent(lang, () => []).add(sub);
    }
    // Sort by language name
    final sortedKeys = grouped.keys.toList()..sort();
    return {for (final key in sortedKeys) key: grouped[key]!};
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
    } catch (e) {
      debugPrint('Failed to load subtitle: $e');
      if (context.mounted) {
        AppSnackBar.showError(
          context,
          message: 'Failed to load subtitle: ${e.toString()}',
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
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  void _showAudioMenu(
    BuildContext context,
    WidgetRef ref,
    List<AudioTrack> tracks,
    AudioTrack? currentTrack,
  ) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    Icon(
                      Icons.audiotrack_rounded,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'Audio',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              ...tracks.map(
                (track) => ListTile(
                  leading: Icon(
                    Icons.audiotrack_rounded,
                    color: currentTrack?.id == track.id
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  title: Text(
                    track.title ?? track.language ?? 'Track ${track.id}',
                  ),
                  subtitle: track.language != null
                      ? Text(track.language!)
                      : null,
                  selected: currentTrack?.id == track.id,
                  onTap: () {
                    ref.read(playerServiceProvider).setAudioTrack(track);
                    Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        );
      },
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
    showModalBottomSheet(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    Icon(Icons.speed_rounded, color: theme.colorScheme.primary),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      'Playback Speed',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              ..._speeds.map(
                (speed) => ListTile(
                  leading: Icon(
                    speed == 1.0
                        ? Icons.check_circle_rounded
                        : Icons.speed_rounded,
                    color: currentRate == speed
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  title: Text(
                    speed == 1.0 ? 'Normal' : '${speed}x',
                    style: TextStyle(
                      fontWeight: currentRate == speed
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                  trailing: currentRate == speed
                      ? Icon(
                          Icons.check_rounded,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                  selected: currentRate == speed,
                  onTap: () {
                    ref.read(playerServiceProvider).setPlaybackRate(speed);
                    Navigator.pop(context);
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        );
      },
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

  const _BottomTrackControls({
    required this.showId,
    required this.isCompact,
    this.onContinueWatchingActivated,
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
        ],
      ),
    );
  }
}

/// Per-show "Continue Watching" pill in the bottom bar.
///
/// Three states:
///   • **Auto** (default, override absent) — outlined pill, follows the
///     global auto-download setting. Tooltip explains.
///   • **On**   — explicit override, force auto-download for this show
///     even if the global toggle is off.
///   • **Off**  — explicit override, never auto-download for this show
///     even if the global toggle is on.
///
/// Tap cycles `Auto → On → Off → Auto`. Persisted in [AutoDownloadState]
/// via `setShowAutoDownloadOverride`. Edge: if the user toggles On
/// mid-episode after the playback already crossed the threshold, the
/// existing one-shot `_autoDownloadTriggered` guard means the trigger
/// won't back-fire for *this* episode — applies from the next.
class _ContinueWatchingToggle extends ConsumerWidget {
  final int showId;
  final double iconSize;

  /// Fired only on the `null → true` and `false → true` transitions, so the
  /// player can kick off auto-download for the next episode immediately
  /// without waiting for the progress threshold.
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
      tooltip = 'Continue Watching: On for this show';
    } else if (override == false) {
      icon = Icons.playlist_remove_rounded;
      label = 'Off';
      bgColor = scheme.surfaceContainerHigh;
      borderColor = Colors.transparent;
      fgColor = scheme.onSurfaceVariant;
      tooltip = 'Continue Watching: Off for this show';
    } else {
      icon = Icons.playlist_play_rounded;
      label = 'Auto';
      bgColor = Colors.transparent;
      borderColor = scheme.outlineVariant.withValues(
        alpha: AppOpacity.semi / 255.0,
      );
      fgColor = scheme.onSurfaceVariant;
      tooltip = 'Continue Watching: Auto (follows global setting)';
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
          debugPrint(
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
            border: Border.all(
              color: borderColor,
              width: AppBorderWidth.thin,
            ),
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
