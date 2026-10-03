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
import '../../services/player_service.dart';
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
    final embeddedTracks = ref.watch(subtitleTracksProvider).value ?? const [];
    final currentTrack = ref.watch(currentSubtitleTrackProvider).value;
    final subtitleContext = ref.watch(subtitleContextProvider);
    final openSubtitlesAsync = ref.watch(availableSubtitlesProvider);
    final sidecars = ref.watch(sidecarSubtitlesProvider);
    final currentExternalSub = ref.watch(currentExternalSubtitleProvider);

    final hasOpenSubtitles = openSubtitlesAsync.value?.isNotEmpty ?? false;
    final hasSubtitleContext = subtitleContext != null;
    final isLoadingOpenSubs =
        openSubtitlesAsync.isLoading && hasSubtitleContext;

    // Show the button when there is something to pick, or OpenSubtitles is
    // still being asked.
    if (embeddedTracks.isEmpty &&
        sidecars.isEmpty &&
        !hasOpenSubtitles &&
        !hasSubtitleContext) {
      return const SizedBox.shrink();
    }

    final subtitlesOn =
        currentExternalSub != null ||
        (currentTrack != null && isRealTrackId(currentTrack.id));

    return Stack(
      children: [
        IconButton(
          tooltip: 'Subtitles',
          iconSize: iconSize,
          icon: Icon(
            subtitlesOn
                ? Icons.closed_caption_rounded
                : Icons.closed_caption_off_rounded,
            color: AppColors.onMedia,
          ),
          onPressed: () => _showSubtitleMenu(context, embeddedTracks),
        ),
        if (isLoadingOpenSubs)
          const Positioned(
            right: AppSpacing.xs,
            top: AppSpacing.xs,
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(AppColors.onMediaMuted),
              ),
            ),
          ),
      ],
    );
  }

  void _showSubtitleMenu(
    BuildContext context,
    List<SubtitleTrack> embeddedTracks,
  ) {
    unawaited(
      MediaHubPickerSheet.show<void>(
        context: context,
        title: 'Subtitles',
        icon: Icons.closed_caption_rounded,
        child: _SubtitleMenu(embeddedTracks: embeddedTracks),
      ),
    );
  }
}

/// The body of the subtitle picker: Off, the file's own tracks, files found
/// beside the video, and OpenSubtitles by language.
class _SubtitleMenu extends ConsumerWidget {
  const _SubtitleMenu({required this.embeddedTracks});

  final List<SubtitleTrack> embeddedTracks;

  static const EdgeInsets _sectionPadding = EdgeInsets.only(
    left: AppSpacing.xxl,
    right: AppSpacing.xxl,
    bottom: AppSpacing.md,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentEmbeddedTrack = ref.watch(currentSubtitleTrackProvider).value;
    final currentExternalSub = ref.watch(currentExternalSubtitleProvider);
    final sidecars = ref.watch(sidecarSubtitlesProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PickerSheetTile(
          icon: Icons.close_rounded,
          title: 'Off',
          selected:
              currentEmbeddedTrack == SubtitleTrack.no() &&
              currentExternalSub == null,
          onTap: () => _pickEmbedded(context, ref, SubtitleTrack.no()),
        ),
        if (embeddedTracks.isNotEmpty) ...[
          const PickerSheetSection(label: 'IN THE VIDEO'),
          for (final track in embeddedTracks)
            PickerSheetTile(
              icon: Icons.subtitles_rounded,
              title: track.title ?? track.language ?? 'Track ${track.id}',
              subtitle: track.title != null ? track.language : null,
              selected:
                  currentEmbeddedTrack?.id == track.id &&
                  currentExternalSub == null,
              onTap: () => _pickEmbedded(context, ref, track),
            ),
        ],
        if (sidecars.isNotEmpty) ...[
          const PickerSheetSection(label: 'IN THIS FOLDER'),
          for (final sidecar in sidecars)
            PickerSheetTile(
              icon: Icons.insert_drive_file_rounded,
              title: sidecar.langName ?? sidecar.url,
              selected: currentExternalSub?.id == sidecar.id,
              onTap: () => currentExternalSub?.id == sidecar.id
                  ? Navigator.pop(context)
                  : _pickExternal(context, ref, sidecar),
            ),
        ],
        ..._openSubtitlesSection(context, ref, currentExternalSub),
      ],
    );
  }

  /// OpenSubtitles results, one chip per language — or why there are none.
  List<Widget> _openSubtitlesSection(
    BuildContext context,
    WidgetRef ref,
    Subtitle? currentExternalSub,
  ) {
    final openSubtitlesAsync = ref.watch(availableSubtitlesProvider);
    final hasSubtitleContext = ref.watch(subtitleContextProvider) != null;
    final openSubtitles = openSubtitlesAsync.value ?? const <Subtitle>[];
    final isLoading = openSubtitlesAsync.isLoading && hasSubtitleContext;
    final note = AppType.caption();

    if (openSubtitles.isEmpty && !isLoading) {
      if (!hasSubtitleContext) return const [];
      return [
        Padding(
          padding: _sectionPadding.copyWith(top: AppSpacing.sm),
          child: Text('No subtitles found on OpenSubtitles', style: note),
        ),
      ];
    }

    bool isCurrent(List<Subtitle> group) =>
        group.any((s) => s.id == currentExternalSub?.id);

    return [
      Padding(
        padding: _sectionPadding.copyWith(
          top: AppSpacing.md,
          bottom: AppSpacing.sm,
        ),
        child: Row(
          children: [
            const MonoLabel('OPENSUBTITLES', letterSpacing: 0.12),
            if (isLoading) ...[
              const SizedBox(width: AppSpacing.sm),
              const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(AppColors.accent),
                ),
              ),
            ],
          ],
        ),
      ),
      Padding(
        padding: _sectionPadding,
        child: openSubtitles.isEmpty
            ? Text('Loading subtitles…', style: note)
            : Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final entry in _groupSubtitlesByLanguage(
                    openSubtitles,
                  ).entries)
                    MediaHubFilterChip(
                      label: entry.key,
                      selected: isCurrent(entry.value),
                      onTap: () => isCurrent(entry.value)
                          ? Navigator.pop(context)
                          : _pickExternal(context, ref, entry.value.first),
                    ),
                ],
              ),
      ),
    ];
  }

  /// Off, or one of the file's own tracks.
  void _pickEmbedded(BuildContext context, WidgetRef ref, SubtitleTrack track) {
    unawaited(ref.read(playerServiceProvider).setSubtitleTrack(track));
    unawaited(ref.read(currentExternalSubtitleProvider.notifier).chooseNone());
    Navigator.pop(context);
  }

  /// Load an external subtitle and remember it for this file.
  ///
  /// Everything needed after the sheet closes is read from [ref] *before* it
  /// closes, because [ref] closes with it. The load is a network round trip,
  /// and it used to finish by calling `ref.read` on the sheet's own
  /// `Consumer` — unmounted by then, so Riverpod threw: the subtitle
  /// appeared, but the choice was never recorded or saved, and a real load
  /// failure showed nothing because its snackbar went to the closed sheet's
  /// context.
  void _pickExternal(BuildContext context, WidgetRef ref, Subtitle subtitle) {
    final player = ref.read(playerServiceProvider);
    final selection = ref.read(currentExternalSubtitleProvider.notifier);
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    unawaited(
      loadExternalSubtitleChoice(
        player: player,
        selection: selection,
        messenger: messenger,
        subtitle: subtitle,
      ),
    );
  }

  /// One entry per language: English first, then A–Z. Multiple
  /// OpenSubtitles files for the same language collapse to the first.
  Map<String, List<Subtitle>> _groupSubtitlesByLanguage(
    List<Subtitle> subtitles,
  ) {
    final grouped = <String, List<Subtitle>>{};
    for (final sub in subtitles) {
      final lang = sub.langName ?? sub.lang;
      grouped.putIfAbsent(lang, () => []).add(sub);
    }

    int rank(String name) {
      final lower = name.toLowerCase();
      if (lower == 'english' || lower == 'en' || lower == 'eng') return 0;
      return 1;
    }

    final keys = grouped.keys.toList()
      ..sort((a, b) {
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return {for (final key in keys) key: grouped[key]!};
  }
}

/// Load [subtitle] into the player and record it as the choice for the
/// playing file, telling [messenger] in plain words if it fails.
///
/// Takes the player service and the selection notifier rather than a
/// `WidgetRef`: the picker closes before the load finishes, and a widget's
/// ref dies with the widget. Both of these belong to the app's provider
/// container and outlive it.
Future<void> loadExternalSubtitleChoice({
  required PlayerService player,
  required CurrentExternalSubtitleNotifier selection,
  required ScaffoldMessengerState? messenger,
  required Subtitle subtitle,
}) async {
  try {
    await player.loadExternalSubtitle(subtitle.url);
    await selection.choose(subtitle);
  } catch (e) {
    AppLog.e('[Subtitles] Failed to load subtitle ${subtitle.url}: $e');
    final language = subtitle.langName;
    AppSnackBar.showOn(
      messenger,
      message: isSidecarSubtitle(subtitle)
          ? "Couldn't load that subtitle file."
          : language == null || language.isEmpty
          ? "Couldn't load those subtitles. Try another."
          : "Couldn't load the $language subtitles. Try another.",
      kind: AppSnackBarKind.error,
    );
  }
}

/// Audio track selector button
class AudioTrackButton extends ConsumerWidget {
  final double iconSize;

  const AudioTrackButton({super.key, this.iconSize = AppIconSize.lg});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Real tracks only (see [isRealTrackId]): with one, there is nothing to
    // choose and the button stays hidden.
    final tracks = ref.watch(audioTracksProvider).value ?? const [];
    if (tracks.length <= 1) return const SizedBox.shrink();

    return IconButton(
      tooltip: 'Audio track',
      iconSize: iconSize,
      icon: const Icon(Icons.audiotrack_rounded, color: AppColors.onMedia),
      onPressed: () => _showAudioMenu(context, tracks),
    );
  }

  void _showAudioMenu(BuildContext context, List<AudioTrack> tracks) {
    unawaited(
      MediaHubPickerSheet.show<void>(
        context: context,
        title: 'Audio',
        icon: Icons.audiotrack_rounded,
        child: Consumer(
          builder: (context, ref, _) {
            final currentTrack = ref.watch(currentAudioTrackProvider).value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final track in tracks)
                  PickerSheetTile(
                    icon: Icons.audiotrack_rounded,
                    title: track.title ?? track.language ?? 'Track ${track.id}',
                    subtitle: track.title != null ? track.language : null,
                    selected: currentTrack?.id == track.id,
                    onTap: () {
                      unawaited(
                        ref.read(playerServiceProvider).setAudioTrack(track),
                      );
                      Navigator.pop(context);
                    },
                  ),
              ],
            );
          },
        ),
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
      message: 'Playback speed',
      child: InkWell(
        onTap: () => _showSpeedMenu(context, ref, currentRate),
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: Container(
          height: iconSize + AppSpacing.md,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: currentRate != 1.0
                ? AppColors.onMedia.withValues(alpha: AppOpacity.medium / 255.0)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Text(
            '${currentRate}x',
            style: AppType.mono(
              size: AppType.sizeBody,
              color: AppColors.onMedia,
              weight: currentRate != 1.0 ? FontWeight.w700 : FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    );
  }

  void _showSpeedMenu(BuildContext context, WidgetRef ref, double currentRate) {
    unawaited(
      MediaHubPickerSheet.show<void>(
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
                  unawaited(
                    ref.read(playerServiceProvider).setPlaybackRate(speed),
                  );
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }
}
