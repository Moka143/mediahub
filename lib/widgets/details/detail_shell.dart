import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../models/video.dart';
import '../../utils/feedback_utils.dart';
import '../editorial/mono_label.dart';
import '../editorial/serif_title.dart';

/// The best trailer to play, or null when there is nothing playable.
///
/// Trailers before teasers, official before fan-cut, and YouTube only — it is
/// the only site we have a render path for. TMDB also returns clips,
/// featurettes and behind-the-scenes, which are noise next to "play the
/// trailer".
Video? bestTrailer(List<Video> videos) {
  final playable = videos.where((v) => v.youtubeUrl != null).toList();
  if (playable.isEmpty) return null;

  int rank(Video v) {
    if (v.isTrailer) return v.official ? 0 : 1;
    if (v.isTeaser) return v.official ? 2 : 3;
    return 4;
  }

  playable.sort((a, b) => rank(a).compareTo(rank(b)));
  return rank(playable.first) == 4 ? null : playable.first;
}

/// Plays the best trailer directly.
///
/// Replaces a whole titled section that listed every clip as a thumbnail
/// card. A details page is read to decide whether to watch the thing; the
/// trailer is one action inside that decision, not a gallery to browse. The
/// clip count still shows, so nothing is hidden — it is just no longer
/// occupying a screen of vertical space.
class TrailerButton extends StatelessWidget {
  const TrailerButton({super.key, required this.videos});

  final List<Video> videos;

  @override
  Widget build(BuildContext context) {
    final trailer = bestTrailer(videos);
    if (trailer == null) return const SizedBox.shrink();

    final others = videos.where((v) => v.youtubeUrl != null).length - 1;

    return OutlinedButton.icon(
      onPressed: () async {
        final ok = await launchUrl(
          Uri.parse(trailer.youtubeUrl!),
          mode: LaunchMode.externalApplication,
        );
        if (!ok && context.mounted) {
          AppSnackBar.showError(context, message: 'Could not open trailer');
        }
      },
      icon: const Icon(Icons.smart_display_outlined, size: 18),
      label: Text(others > 0 ? 'Trailer  ·  ${others + 1}' : 'Trailer'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.fg,
        side: const BorderSide(color: AppColors.line),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
      ),
    );
  }
}

/// A titled section that folds away.
///
/// Everything below the hero used to be permanently expanded, so a details
/// page ran to several screens of scrolling for information most visits do
/// not need. Folding is the compromise between hiding it and making the user
/// scroll past it: the heading stays as a signpost, and the content is one
/// click away.
class FoldableSection extends StatefulWidget {
  const FoldableSection({
    super.key,
    required this.title,
    required this.child,
    this.count,
    this.initiallyExpanded = false,
  });

  final String title;

  /// Small mono label beside the title — "12+ CREDITS". Shown collapsed too,
  /// so the heading says how much is behind it before it is opened.
  final String? count;

  final Widget child;
  final bool initiallyExpanded;

  @override
  State<FoldableSection> createState() => _FoldableSectionState();
}

class _FoldableSectionState extends State<FoldableSection>
    with SingleTickerProviderStateMixin {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.detailPadding,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  AnimatedRotation(
                    duration: AppDuration.fast,
                    turns: _expanded ? 0.25 : 0.0,
                    child: const Icon(
                      Icons.chevron_right_rounded,
                      color: AppColors.fg2,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 6),
                  SerifTitle(widget.title, size: 22, height: 1.0),
                  if (widget.count != null) ...[
                    const SizedBox(width: 12),
                    MonoLabel(widget.count!, color: AppColors.fg3),
                  ],
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: widget.child,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// A horizontal scroller that stays out of the way until you point at it.
///
/// Dimmed at rest, full strength on hover, with scroll arrows that only
/// appear then — and only on the side there is actually more content. A row
/// of suggestions is peripheral: it should read as "more, if you want it"
/// rather than competing with the page it sits under. The arrows exist
/// because a trackpad swipe is not discoverable and a scrollbar under a row
/// of posters is noise.
class HoverScrollRow extends StatefulWidget {
  const HoverScrollRow({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.detailPadding,
    ),
    this.restingOpacity = 0.55,
    this.scrollStep = 600,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;

  /// How visible the row is before the pointer arrives.
  final double restingOpacity;

  /// Pixels one arrow press travels. Roughly two cards.
  final double scrollStep;

  @override
  State<HoverScrollRow> createState() => _HoverScrollRowState();
}

class _HoverScrollRowState extends State<HoverScrollRow> {
  final _controller = ScrollController();
  bool _hovered = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncArrows);
    // The first frame has no scroll metrics yet, so the right arrow would
    // never appear for a row that has not been touched.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrows());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncArrows() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final left = position.pixels > 1;
    final right = position.pixels < position.maxScrollExtent - 1;
    if (left != _canScrollLeft || right != _canScrollRight) {
      setState(() {
        _canScrollLeft = left;
        _canScrollRight = right;
      });
    }
  }

  void _scrollBy(double delta) {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      (_controller.offset + delta).clamp(
        0.0,
        _controller.position.maxScrollExtent,
      ),
      duration: AppDuration.normal,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        duration: AppDuration.normal,
        opacity: _hovered ? 1.0 : widget.restingOpacity,
        child: SizedBox(
          height: widget.height,
          child: Stack(
            children: [
              ListView.separated(
                controller: _controller,
                scrollDirection: Axis.horizontal,
                padding: widget.padding,
                itemCount: widget.itemCount,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: AppSpacing.md),
                itemBuilder: widget.itemBuilder,
              ),
              _arrow(left: true, visible: _hovered && _canScrollLeft),
              _arrow(left: false, visible: _hovered && _canScrollRight),
            ],
          ),
        ),
      ),
    );
  }

  Widget _arrow({required bool left, required bool visible}) {
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          duration: AppDuration.fast,
          opacity: visible ? 1 : 0,
          child: Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              decoration: BoxDecoration(
                color: AppColors.bgPage.withValues(alpha: 0.82),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.line),
              ),
              child: IconButton(
                iconSize: 20,
                color: AppColors.fg,
                icon: Icon(
                  left
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                ),
                onPressed: () =>
                    _scrollBy(left ? -widget.scrollStep : widget.scrollStep),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
