import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/episode.dart';
import '../common/hub_pressable.dart';
import '../editorial/editorial.dart';
import '../media/hue_backdrop.dart';
import 'episode_status.dart';

/// One episode in the episodes drawer. The whole row is the button: click,
/// Enter or Space opens the episode.
///
/// Rows have one fixed height ([extentFor]) so the list can scroll straight
/// to any episode — including ones not built yet — by arithmetic.
class EpisodeRow extends StatefulWidget {
  const EpisodeRow({
    super.key,
    required this.episode,
    required this.status,
    required this.onTap,
    this.watchedRatio,
  });

  final Episode episode;
  final EpisodeStatus status;
  final VoidCallback onTap;

  /// 0.0–1.0 if the user has watched part/all of the episode. Renders a
  /// thin progress bar along the bottom of the still.
  final double? watchedRatio;

  static const double _stillHeight = 60;
  static const double _padding = AppSpacing.md;
  static const double _gap = AppSpacing.xs;

  // Line heights set on the text below, so [extentFor] measures what is
  // drawn rather than guessing at the fonts' natural metrics.
  static const double _nameSize = AppType.sizeBody;
  static const double _nameHeight = 1.25;
  static const double _overviewSize = AppType.sizeSmall;
  static const double _overviewHeight = 1.4;
  static const double _metaSize = AppType.sizeLabel;
  static const double _metaHeight = 1.3;

  /// The height of every row, under [scaler].
  ///
  /// Tall enough for a one-line name, a two-line overview and the meta line
  /// at the current text size; shorter rows centre in it.
  static double extentFor(TextScaler scaler) {
    final text =
        scaler.scale(_nameSize) * _nameHeight +
        2 +
        scaler.scale(_overviewSize) * _overviewHeight * 2 +
        4 +
        scaler.scale(_metaSize) * _metaHeight +
        2;
    final content = text > _stillHeight ? text : _stillHeight;
    return (content + _padding * 2 + _gap).ceilToDouble();
  }

  @override
  State<EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<EpisodeRow> {
  bool _hover = false;
  bool _focus = false;

  String? _airDateLabel(String? raw) {
    final date = parseAirDate(raw);
    return date == null ? null : DateFormat('MMM d, y').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final active = _hover || _focus;
    final airDate = _airDateLabel(ep.airDate);

    return Padding(
      padding: const EdgeInsets.only(bottom: EpisodeRow._gap),
      child: HubPressable(
        onTap: widget.onTap,
        onHoverChanged: (h) => setState(() => _hover = h),
        onFocusChanged: (f) => setState(() => _focus = f),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AnimatedScale(
          // Subtle lift so the row feels tactile.
          scale: active ? 1.012 : 1.0,
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: AppDuration.fast,
            padding: const EdgeInsets.all(EpisodeRow._padding),
            decoration: BoxDecoration(
              color: active ? AppColors.bgSurfaceHi : AppColors.bgSurface,
              border: Border.all(
                color: active ? AppColors.lineStrong : AppColors.line,
              ),
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: AppColors.shadow.withValues(alpha: 0.25),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        ep.episodeNumber.toString().padLeft(2, '0'),
                        textAlign: TextAlign.center,
                        // Watched episodes dim so unwatched ones stand out.
                        style: AppType.mono(
                          size: AppType.sizeHeading,
                          color: widget.status == EpisodeStatus.watched
                              ? AppColors.fg2
                              : AppColors.fg,
                          weight: FontWeight.w800,
                          letterSpacing: -0.02,
                        ),
                      ),
                      if (widget.status.icon != null)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: widget.status.color.withAlpha(
                                AppOpacity.light,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              widget.status.icon,
                              size: 10,
                              color: widget.status.color,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    width: 100,
                    height: EpisodeRow._stillHeight,
                    child: EpisodeStill(
                      stillUrl: ep.stillUrl,
                      hue: hueForText(ep.name),
                      watchedRatio: widget.watchedRatio,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ep.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          size: EpisodeRow._nameSize,
                          color: AppColors.fg,
                          weight: FontWeight.w600,
                          height: EpisodeRow._nameHeight,
                        ),
                      ),
                      if (ep.overview != null && ep.overview!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          ep.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.ui(
                            size: EpisodeRow._overviewSize,
                            color: AppColors.fg1,
                            height: EpisodeRow._overviewHeight,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      // Status is not repeated here: the icon under the
                      // number and the action label already carry it.
                      Text(
                        [
                          ?airDate,
                          if (ep.runtime != null) '${ep.runtime} min',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.mono(
                          size: EpisodeRow._metaSize,
                          color: AppColors.fg2,
                          letterSpacing: 0.04,
                          height: EpisodeRow._metaHeight,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                EpisodeActionLabel(status: widget.status, active: active),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What opening the row will do, drawn like a button. The row itself is
/// the button — this used to be a second, mouse-only tap target with the
/// same action, and could not be reached from the keyboard.
class EpisodeActionLabel extends StatelessWidget {
  const EpisodeActionLabel({
    super.key,
    required this.status,
    required this.active,
  });

  final EpisodeStatus status;

  /// Row hovered or focused — the label fills in.
  final bool active;

  ({IconData icon, String label, Color color}) _spec() {
    return switch (status) {
      EpisodeStatus.watched => (
        icon: Icons.replay_rounded,
        label: 'Rewatch',
        color: AppColors.fg1,
      ),
      EpisodeStatus.downloaded => (
        icon: Icons.play_arrow_rounded,
        label: 'Play',
        color: AppColors.ok,
      ),
      EpisodeStatus.downloading => (
        icon: Icons.downloading_rounded,
        label: 'Downloading',
        color: AppColors.accent,
      ),
      EpisodeStatus.none => (
        icon: Icons.play_circle_outline_rounded,
        label: 'Stream',
        color: AppColors.accent,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec();
    // Dark text on the filled state: white on this orange is 2.7:1, and on
    // the green 1.9:1.
    final fg = active ? AppColors.onAccent : spec.color;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: active ? spec.color : spec.color.withAlpha(AppOpacity.light),
        border: Border.all(color: spec.color.withAlpha(AppOpacity.semi)),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(spec.icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            spec.label,
            style: AppType.ui(
              size: AppType.sizeCaption,
              color: fg,
              weight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Episode still with a [HueBackdrop] while it loads or when TMDB has none.
///
/// When [watchedRatio] is set, a progress bar along the bottom shows how far
/// the user got.
class EpisodeStill extends StatelessWidget {
  const EpisodeStill({
    super.key,
    required this.stillUrl,
    required this.hue,
    this.watchedRatio,
  });

  final String? stillUrl;
  final double hue;
  final double? watchedRatio;

  @override
  Widget build(BuildContext context) {
    final placeholder = HueBackdrop(hue: hue);
    final url = stillUrl;
    final image = (url == null || url.isEmpty)
        ? placeholder
        : CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            // 100 logical px wide; twice that covers a 2× display.
            memCacheWidth: 240,
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          );

    final ratio = watchedRatio;
    if (ratio == null || ratio <= 0) return image;

    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        // Dim watched stills a touch so unwatched ones pop.
        Container(color: AppColors.mediaBlack.withAlpha(AppOpacity.light)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: EditorialProgress(value: ratio),
        ),
      ],
    );
  }
}
