import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../providers/player_provider.dart';
import '../providers/subtitle_provider.dart';
import '../services/opensubtitles_service.dart';

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
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final duration = ref.watch(playbackDurationProvider).value ?? Duration.zero;
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
            Expanded(
              child: Center(
                child: _buildCenterControls(context),
              ),
            ),

            // Bottom controls
            _buildBottomControls(context, ref, position, duration, volume),
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

          // Subtitle button
          _SubtitleButton(),

          // Audio track button
          _AudioTrackButton(),
          
          // Playback speed button
          _PlaybackSpeedButton(),
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
              icon: Icon(Icons.replay_10_rounded, size: AppIconSize.xl, color: Colors.white),
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
              icon: Icon(Icons.forward_10_rounded, size: AppIconSize.xl, color: Colors.white),
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
    double volume,
  ) {
    final playerService = ref.read(playerServiceProvider);

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
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: duration.inMilliseconds > 0
                        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                        : 0.0,
                    onChanged: (value) {
                      if (duration.inMilliseconds > 0) {
                        final newPosition = Duration(
                          milliseconds: (value * duration.inMilliseconds).round(),
                        );
                        playerService.seek(newPosition);
                      }
                    },
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

          // Bottom buttons
          Row(
            children: [
              // Volume control
              _VolumeControl(
                volume: volume,
                onVolumeChanged: (v) => playerService.setVolume(v),
              ),

              const Spacer(),

              // Fullscreen toggle
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: IconButton(
                  icon: Icon(
                    isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
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

  const _VolumeControl({
    required this.volume,
    required this.onVolumeChanged,
  });

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
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
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
    final isLoadingOpenSubs = openSubtitlesAsync.isLoading && hasSubtitleContext;

    // Show button if we have embedded tracks, OpenSubtitles, or context to fetch
    if (!hasEmbeddedTracks && !hasOpenSubtitles && !hasSubtitleContext) {
      return const SizedBox.shrink();
    }

    return Stack(
      children: [
        IconButton(
          icon: Icon(
            currentExternalSub != null || (currentTrackAsync.value != null && currentTrackAsync.value != SubtitleTrack.no())
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
                valueColor: AlwaysStoppedAnimation(Colors.white.withValues(alpha: 0.7)),
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
                          color: (currentEmbeddedTrack == SubtitleTrack.no() && currentExternalSub == null)
                              ? theme.colorScheme.primary
                              : null,
                        ),
                        title: const Text('Off'),
                        selected: currentEmbeddedTrack == SubtitleTrack.no() && currentExternalSub == null,
                        onTap: () {
                          ref.read(playerServiceProvider).setSubtitleTrack(SubtitleTrack.no());
                          ref.read(currentExternalSubtitleProvider.notifier).clear();
                          Navigator.pop(context);
                        },
                      ),

                      // Embedded tracks section
                      if (embeddedTracks.isNotEmpty) ...[
                        Padding(
                          padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
                          child: Text(
                            'Embedded Subtitles',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ...embeddedTracks.map((track) => ListTile(
                          leading: Icon(
                            Icons.subtitles_rounded,
                            color: currentEmbeddedTrack?.id == track.id && currentExternalSub == null
                                ? theme.colorScheme.primary
                                : null,
                          ),
                          title: Text(track.title ?? track.language ?? 'Track ${track.id}'),
                          subtitle: track.language != null ? Text(track.language!) : null,
                          selected: currentEmbeddedTrack?.id == track.id && currentExternalSub == null,
                          onTap: () {
                            ref.read(playerServiceProvider).setSubtitleTrack(track);
                            ref.read(currentExternalSubtitleProvider.notifier).clear();
                            Navigator.pop(context);
                          },
                        )),
                      ],

                      // OpenSubtitles section
                      if (openSubtitles.isNotEmpty || isLoadingOpenSubs) ...[
                        Padding(
                          padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
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
                                    valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
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
                                onTap: () => _loadExternalSubtitle(ref, firstSub, context),
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
                                  onTap: () => _loadExternalSubtitle(ref, sub, context),
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
                      if (openSubtitles.isEmpty && !isLoadingOpenSubs && ref.read(subtitleContextProvider) != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
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

  Map<String, List<Subtitle>> _groupSubtitlesByLanguage(List<Subtitle> subtitles) {
    final Map<String, List<Subtitle>> grouped = {};
    for (final sub in subtitles) {
      final lang = sub.langName ?? sub.lang;
      grouped.putIfAbsent(lang, () => []).add(sub);
    }
    // Sort by language name
    final sortedKeys = grouped.keys.toList()..sort();
    return {for (final key in sortedKeys) key: grouped[key]!};
  }

  Future<void> _loadExternalSubtitle(WidgetRef ref, Subtitle subtitle, BuildContext context) async {
    Navigator.pop(context);
    
    try {
      // Load the subtitle URL directly in media_kit
      await ref.read(playerServiceProvider).loadExternalSubtitle(subtitle.url);
      ref.read(currentExternalSubtitleProvider.notifier).set(subtitle);
    } catch (e) {
      debugPrint('Failed to load subtitle: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load subtitle: ${e.toString()}')),
        );
      }
    }
  }
}

/// Audio track selector button
class _AudioTrackButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audioTracksAsync = ref.watch(audioTracksProvider);
    final currentTrackAsync = ref.watch(currentAudioTrackProvider);

    return audioTracksAsync.when(
      data: (tracks) {
        if (tracks.length <= 1) return const SizedBox.shrink();

        return IconButton(
          icon: const Icon(Icons.audiotrack_rounded, color: Colors.white),
          onPressed: () => _showAudioMenu(context, ref, tracks, currentTrackAsync.value),
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
              ...tracks.map((track) => ListTile(
                    leading: Icon(
                      Icons.audiotrack_rounded,
                      color: currentTrack?.id == track.id
                          ? theme.colorScheme.primary
                          : null,
                    ),
                    title: Text(track.title ?? track.language ?? 'Track ${track.id}'),
                    subtitle: track.language != null ? Text(track.language!) : null,
                    selected: currentTrack?.id == track.id,
                    onTap: () {
                      ref.read(playerServiceProvider).setAudioTrack(track);
                      Navigator.pop(context);
                    },
                  )),
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
  static const List<double> _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentRate = ref.watch(playbackRateProvider).value ?? 1.0;
    
    return Tooltip(
      message: 'Playback speed',
      child: InkWell(
        onTap: () => _showSpeedMenu(context, ref, currentRate),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: currentRate != 1.0 
                ? Colors.white.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            '${currentRate}x',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: currentRate != 1.0 ? FontWeight.bold : FontWeight.normal,
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
                    Icon(
                      Icons.speed_rounded,
                      color: theme.colorScheme.primary,
                    ),
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
              ..._speeds.map((speed) => ListTile(
                    leading: Icon(
                      speed == 1.0 ? Icons.check_circle_rounded : Icons.speed_rounded,
                      color: currentRate == speed
                          ? theme.colorScheme.primary
                          : null,
                    ),
                    title: Text(
                      speed == 1.0 ? 'Normal' : '${speed}x',
                      style: TextStyle(
                        fontWeight: currentRate == speed ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    trailing: currentRate == speed 
                        ? Icon(Icons.check_rounded, color: theme.colorScheme.primary)
                        : null,
                    selected: currentRate == speed,
                    onTap: () {
                      ref.read(playerServiceProvider).setPlaybackRate(speed);
                      Navigator.pop(context);
                    },
                  )),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        );
      },
    );
  }
}
