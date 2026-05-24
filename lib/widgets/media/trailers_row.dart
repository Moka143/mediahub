import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/video.dart';
import '../../utils/feedback_utils.dart';
import '../editorial/mono_label.dart';
import '../editorial/serif_title.dart';

/// Horizontal scroller of trailer / teaser thumbnails.
///
/// Fed by `Show.videos` / `Movie.videos`. Filters down to YouTube
/// trailers + teasers (TMDB also returns clips, featurettes,
/// behind-the-scenes — those are noisier and we hide them by default).
/// Tap a card → launches the YouTube URL in the system default
/// browser.
class TrailersRow extends StatelessWidget {
  const TrailersRow({super.key, required this.videos, this.maxItems = 8});

  final List<Video> videos;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    // Trailers first, then teasers — both must be on YouTube to be
    // playable. Skip non-YouTube sites (Vimeo etc are rare and we
    // don't have a render path).
    final ranked = [
      ...videos.where((v) => v.isTrailer && v.youtubeUrl != null),
      ...videos.where((v) => v.isTeaser && v.youtubeUrl != null),
    ];
    if (ranked.isEmpty) return const SizedBox.shrink();
    final items = ranked.take(maxItems).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenPadding,
            0,
            AppSpacing.screenPadding,
            AppSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              const SerifTitle('Trailers', size: 22, height: 1.0),
              const SizedBox(width: 12),
              MonoLabel(
                '${items.length} ${items.length == 1 ? 'CLIP' : 'CLIPS'}',
                color: AppColors.fg3,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
            ),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
            itemBuilder: (_, i) => _TrailerCard(video: items[i]),
          ),
        ),
      ],
    );
  }
}

class _TrailerCard extends StatefulWidget {
  const _TrailerCard({required this.video});

  final Video video;

  @override
  State<_TrailerCard> createState() => _TrailerCardState();
}

class _TrailerCardState extends State<_TrailerCard> {
  bool _hover = false;

  Future<void> _open() async {
    final url = widget.video.youtubeUrl;
    if (url == null) return;
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      AppSnackBar.showError(context, message: 'Could not open trailer');
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.video;
    final thumb = v.thumbnailUrl;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _open,
        child: AnimatedContainer(
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          transform: Matrix4.identity()
            ..translateByDouble(0.0, _hover ? -2.0 : 0.0, 0.0, 1.0),
          width: 220,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    SizedBox(
                      width: 220,
                      height: 124,
                      child: thumb != null
                          ? CachedNetworkImage(
                              imageUrl: thumb,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => _placeholder(),
                              placeholder: (_, _) => _placeholder(),
                            )
                          : _placeholder(),
                    ),
                    // Bottom scrim so the play badge reads on bright frames
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, AppColors.scrimSoft],
                          ),
                        ),
                      ),
                    ),
                    // Center play badge
                    Positioned.fill(
                      child: Center(
                        child: AnimatedScale(
                          duration: AppDuration.fast,
                          curve: Curves.easeOutCubic,
                          scale: _hover ? 1.08 : 1.0,
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.accent.withAlpha(140),
                                  blurRadius: 16,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Type chip (top-left)
                    Positioned(
                      top: AppSpacing.sm,
                      left: AppSpacing.sm,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.bgPage.withAlpha(200),
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: Text(
                          v.type.toUpperCase(),
                          style: AppType.mono(
                            size: 9,
                            color: AppColors.fg,
                            weight: FontWeight.w700,
                            letterSpacing: 0.08,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                v.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.ui(
                  size: 12,
                  color: AppColors.fg,
                  weight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: AppColors.bgSurfaceHi,
      child: const Center(
        child: Icon(
          Icons.movie_outlined,
          color: AppColors.fg3,
          size: AppIconSize.xl,
        ),
      ),
    );
  }
}
