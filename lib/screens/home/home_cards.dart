import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../models/torrent.dart';
import '../../models/watch_progress.dart';
import '../../providers/local_media_provider.dart';
import '../../utils/media_names.dart';
import '../../utils/media_quality.dart';
import '../../utils/platform_utils.dart';
import '../../widgets/editorial/editorial.dart';
import 'home_hero_data.dart';

class ContinueCard extends ConsumerWidget {
  const ContinueCard({
    super.key,
    required this.p,
    this.posterFallback,
    this.onTap,
  });

  final WatchProgress p;

  /// Optional poster path used when `p.posterPath` is missing.
  final String? posterFallback;

  /// Tapping anywhere on the card resumes playback at the saved
  /// position. Wired up by the home screen.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hue =
        (p.showName?.codeUnits.fold<int>(0, (a, b) => a + b) ?? 220) % 360;
    final progressFraction = p.duration.inSeconds == 0
        ? 0.0
        : p.position.inSeconds / p.duration.inSeconds;
    // Pick the best poster path we have: native first, then fallback.
    final posterPath = (p.posterPath != null && p.posterPath!.isNotEmpty)
        ? p.posterPath
        : posterFallback;
    String? url = tmdbPoster(posterPath, size: 'w780');

    // Last-resort TMDB lookup keyed on the show name (or filename) —
    // older watch-progress entries were created before posters were
    // captured, so we resolve them on demand here.
    if (url == null) {
      final fileName = basenameOf(p.filePath);
      final query = (p.showName != null && p.showName!.isNotEmpty)
          ? p.showName!
          : searchTitleFromTorrentName(fileName);
      if (query.isNotEmpty) {
        final isShow = p.episodeCode != null;
        final asyncPoster = isShow
            ? ref.watch(showPosterProvider(query))
            : ref.watch(moviePosterProvider(query));
        url = asyncPoster.maybeWhen(
          data: (u) => (u != null && u.isNotEmpty) ? u : null,
          orElse: () => null,
        );
      }
    }
    return SizedBox(
      width: 280,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: SizedBox(
                      width: 280,
                      height: 158,
                      child: url != null
                          ? CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => hueBackdrop(hue),
                              placeholder: (_, _) => hueBackdrop(hue),
                            )
                          : hueBackdrop(hue),
                    ),
                  ),
                  // Subtle bottom darkening so the title overlay reads.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 80,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(AppRadius.md),
                        bottomRight: Radius.circular(AppRadius.md),
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, AppColors.scrimStrong],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Resume play badge — solid white pill so it reads as
                  // an actionable control, not a faint overlay.
                  Positioned(
                    top: AppSpacing.sm,
                    right: AppSpacing.sm,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: AppColors.scrimSoft, blurRadius: 10),
                        ],
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        size: 22,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SizedBox(
                      height: 3,
                      child: Stack(
                        children: [
                          Container(color: AppColors.glassBorder),
                          FractionallySizedBox(
                            widthFactor: progressFraction.clamp(0.0, 1.0),
                            child: Container(color: AppColors.seedColor),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm + 2),
              SerifTitle(
                p.showName ?? p.episodeTitle ?? 'Untitled',
                size: 18,
                height: 1.1,
                maxLines: 1,
              ),
              const SizedBox(height: 4),
              MonoLabel(
                [
                  if (p.episodeCode != null) p.episodeCode!,
                  if (p.episodeTitle != null) p.episodeTitle!,
                ].join(' · '),
                color: AppColors.fg3,
                letterSpacing: 0.08,
                uppercase: false,
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 180×220 poster tile used in the Home "Trending" rows. Displays a
/// real TMDB poster when `imageUrl` is provided, falling back to a
/// hue gradient. Tapping opens the matching detail screen via
/// the supplied `onTap`.
class PosterTile extends StatefulWidget {
  const PosterTile({
    super.key,
    required this.imageUrl,
    required this.hue,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String? imageUrl;
  final double hue;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  State<PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<PosterTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          transform: Matrix4.identity()
            ..translateByDouble(0.0, _hover ? -4.0 : 0.0, 0.0, 1.0),
          width: 180,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: SizedBox(
                  width: 180,
                  height: 220,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.imageUrl != null &&
                          widget.imageUrl!.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: widget.imageUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              hueBackdrop(widget.hue.toInt()),
                          placeholder: (_, _) =>
                              hueBackdrop(widget.hue.toInt()),
                        )
                      else
                        hueBackdrop(widget.hue.toInt()),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm + 2),
              SerifTitle(widget.title, size: 18, height: 1.1, maxLines: 1),
              if (widget.subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: MonoLabel(
                    widget.subtitle!,
                    color: AppColors.fg3,
                    letterSpacing: 0.08,
                    uppercase: false,
                    maxLines: 1,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class FreshTile extends ConsumerWidget {
  const FreshTile({super.key, required this.t, this.posterPath});

  final Torrent t;

  /// Resolved TMDB poster path (e.g. `/abc.jpg`) — comes from joining
  /// the torrent name against watch progress + local media library.
  /// Falls back to a hue gradient when null.
  final String? posterPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hue = t.name.codeUnits.fold<int>(0, (a, b) => a + b) % 360;
    final quality = qualityBadgeLabel(t.name);
    String? url = tmdbPoster(posterPath, size: 'w500');

    // No poster from local progress / library — fall back to a live
    // TMDB lookup against the cleaned torrent name. Show vs. movie
    // is decided by whether the name contains a season/episode tag.
    if (url == null) {
      final isShow = RegExp(
        r'[Ss]\d{1,2}[Ee]\d{1,2}|\d{1,2}x\d{1,2}',
      ).hasMatch(t.name);
      final query = searchTitleFromTorrentName(t.name);
      if (query.isNotEmpty) {
        final asyncPoster = isShow
            ? ref.watch(showPosterProvider(query))
            : ref.watch(moviePosterProvider(query));
        url = asyncPoster.maybeWhen(
          data: (u) => (u != null && u.isNotEmpty) ? u : null,
          orElse: () => null,
        );
      }
    }
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: SizedBox(
              width: 180,
              height: 220,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (url != null)
                    CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => hueBackdrop(hue),
                      placeholder: (_, _) => hueBackdrop(hue),
                    )
                  else
                    hueBackdrop(hue),
                  Positioned(
                    top: AppSpacing.sm,
                    right: AppSpacing.sm,
                    child: EditorialBadge(
                      quality,
                      compact: true,
                      tone: quality.qualityColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm + 2),
          SerifTitle(shortName(t.name), size: 18, height: 1.1, maxLines: 1),
          const SizedBox(height: 4),
          MonoLabel(
            'NEW · ${quality.toUpperCase()}',
            color: AppColors.fg3,
            letterSpacing: 0.08,
          ),
        ],
      ),
    );
  }
}

String shortName(String n) {
  final cleaned = n.split(RegExp(r'[\.\s]')).take(4).join(' ');
  return cleaned.isEmpty ? n : cleaned;
}
