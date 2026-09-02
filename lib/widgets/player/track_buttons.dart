import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../providers/player_provider.dart';
import '../../providers/subtitle_provider.dart';
import '../../services/app_logger.dart';
import '../../services/opensubtitles_service.dart';
import '../../utils/feedback_utils.dart';
import '../common/mediahub_chip.dart';
import '../common/mediahub_picker_sheet.dart';
import '../editorial/editorial.dart';

/// Subtitle track selector button with OpenSubtitles support
class SubtitleButton extends ConsumerWidget {
  final double iconSize;

  const SubtitleButton({super.key, this.iconSize = AppIconSize.lg});

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
class AudioTrackButton extends ConsumerWidget {
  final double iconSize;

  const AudioTrackButton({super.key, this.iconSize = AppIconSize.lg});

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
class PlaybackSpeedButton extends ConsumerWidget {
  final double iconSize;

  const PlaybackSpeedButton({super.key, this.iconSize = AppIconSize.lg});

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
