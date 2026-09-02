import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/episode.dart';
import 'episode_picker.dart';

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
  /// thin tertiary-colored progress bar at the bottom of the still.
  final double? watchedRatio;

  @override
  State<EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<EpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final hue = (ep.name.codeUnits.fold<int>(0, (a, b) => a + b)) % 360;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          // Subtle hover lift so the row feels tactile.
          scale: _hover ? 1.012 : 1.0,
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: AppDuration.fast,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: _hover ? AppColors.bgSurfaceHi : AppColors.bgSurface,
              border: Border.all(
                color: _hover ? const Color(0x33FFFFFF) : AppColors.line,
              ),
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: _hover
                  ? const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 36,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        ep.episodeNumber.toString().padLeft(2, '0'),
                        textAlign: TextAlign.center,
                        // Watched episodes dim slightly so the user
                        // can scan unwatched ones at a glance.
                        style: AppType.mono(
                          size: 18,
                          color: widget.status == EpisodeStatus.watched
                              ? AppColors.fg2
                              : AppColors.fg,
                          weight: FontWeight.w800,
                          letterSpacing: -0.02,
                        ),
                      ),
                      if (widget.status.icon != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: widget.status.color.withAlpha(36),
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
                    height: 60,
                    child: EpisodeStill(
                      stillUrl: ep.stillUrl,
                      hue: hue,
                      watchedRatio: widget.watchedRatio,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ep.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.fg,
                        ),
                      ),
                      if (ep.overview != null && ep.overview!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          ep.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.fg1,
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            [
                              if (ep.airDate != null) ep.airDate!.toUpperCase(),
                              if (ep.runtime != null) '${ep.runtime}m',
                            ].join(' · '),
                            style: AppType.mono(
                              size: 10,
                              color: AppColors.fg2,
                              letterSpacing: 0.04,
                            ),
                          ),
                          if (widget.status != EpisodeStatus.none) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: widget.status.color.withAlpha(36),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.xs,
                                ),
                              ),
                              child: Text(
                                widget.status.label.toUpperCase(),
                                style: AppType.mono(
                                  size: 9,
                                  color: widget.status.color,
                                  weight: FontWeight.w700,
                                  letterSpacing: 0.055,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                EpisodeActionButton(
                  status: widget.status,
                  hover: _hover,
                  onTap: widget.onTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Episode-row action button — switches label + icon + accent color
/// based on the lifecycle status. Replaces the always-`GET` button.
class EpisodeActionButton extends StatelessWidget {
  const EpisodeActionButton({
    super.key,
    required this.status,
    required this.hover,
    required this.onTap,
  });

  final EpisodeStatus status;
  final bool hover;
  final VoidCallback onTap;

  ({IconData icon, String label, Color color}) _spec() {
    return switch (status) {
      EpisodeStatus.watched => (
        icon: Icons.replay_rounded,
        label: 'REWATCH',
        color: AppColors.seeding,
      ),
      EpisodeStatus.downloaded => (
        icon: Icons.play_arrow_rounded,
        label: 'OPEN',
        color: AppColors.seeding,
      ),
      EpisodeStatus.downloading => (
        icon: Icons.downloading_rounded,
        label: 'IN PROGRESS',
        color: AppColors.downloading,
      ),
      EpisodeStatus.none => (
        icon: Icons.download_rounded,
        label: 'GET',
        color: AppColors.seedColor,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hover ? spec.color : spec.color.withAlpha(36),
          border: Border.all(color: spec.color.withAlpha(0x66)),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(spec.icon, size: 11, color: hover ? Colors.white : spec.color),
            const SizedBox(width: 4),
            Text(
              spec.label,
              style: AppType.mono(
                size: 11,
                color: hover ? Colors.white : spec.color,
                weight: FontWeight.w700,
                letterSpacing: 0.05,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Episode still image with a deterministic gradient placeholder fallback
/// (driven by the episode title hash so each row is visually distinct
/// while loading or when TMDB has no still).
///
/// When [watchedRatio] is set, a thin tertiary-tinted progress bar runs
/// along the bottom of the still showing the user how far they got — a
/// glanceable "you watched this much" cue.
class EpisodeStill extends StatelessWidget {
  const EpisodeStill({
    super.key,
    required this.stillUrl,
    required this.hue,
    this.watchedRatio,
  });

  final String? stillUrl;
  final int hue;
  final double? watchedRatio;

  @override
  Widget build(BuildContext context) {
    final placeholder = _gradientPlaceholder();
    final url = stillUrl;
    final image = (url == null || url.isEmpty)
        ? placeholder
        : Image.network(
            url,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return placeholder;
            },
            errorBuilder: (_, _, _) => placeholder,
          );

    final ratio = watchedRatio;
    if (ratio == null || ratio <= 0) return image;

    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        // Subtle dim on already-watched portion so unwatched stills pop.
        Container(
          color: Colors.black.withValues(alpha: AppOpacity.light / 255.0),
        ),
        // Progress bar pinned to the bottom edge.
        Align(
          alignment: Alignment.bottomLeft,
          child: FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: Container(height: 3, color: scheme.tertiary),
          ),
        ),
      ],
    );
  }

  Widget _gradientPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.32).toColor(),
            HSLColor.fromAHSL(1, (hue + 30) % 360, 0.5, 0.16).toColor(),
          ],
        ),
      ),
    );
  }
}
