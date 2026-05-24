import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/cast_member.dart';
import '../editorial/mono_label.dart';
import '../editorial/serif_title.dart';

/// Horizontal scroller of cast cards.
///
/// Fed by `Show.cast` / `Movie.cast`. Each card is a circular
/// headshot + name + character. Limits to [maxItems] so the row
/// doesn't stretch to 100+ entries from `aggregate_credits`.
class CastRow extends StatelessWidget {
  const CastRow({super.key, required this.cast, this.maxItems = 12});

  final List<CastMember> cast;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) return const SizedBox.shrink();

    // Sort by TMDB `order` (lowest first = top billing) and clip.
    final sorted = [...cast]..sort((a, b) => a.order.compareTo(b.order));
    final items = sorted.take(maxItems).toList();

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
              const SerifTitle('Cast', size: 22, height: 1.0),
              const SizedBox(width: 12),
              MonoLabel(
                '${cast.length > maxItems ? '$maxItems+' : '${cast.length}'} '
                'CREDITS',
                color: AppColors.fg3,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.screenPadding,
            ),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
            itemBuilder: (_, i) => _CastCard(member: items[i]),
          ),
        ),
      ],
    );
  }
}

class _CastCard extends StatelessWidget {
  const _CastCard({required this.member});

  final CastMember member;

  @override
  Widget build(BuildContext context) {
    final profile = member.profileUrl;
    final initial = member.name.isNotEmpty ? member.name[0].toUpperCase() : '?';

    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipOval(
            child: SizedBox(
              width: 96,
              height: 96,
              child: profile != null
                  ? CachedNetworkImage(
                      imageUrl: profile,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _initialBubble(initial),
                      placeholder: (_, _) => _initialBubble(initial),
                    )
                  : _initialBubble(initial),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.ui(
              size: 12,
              color: AppColors.fg,
              weight: FontWeight.w500,
              height: 1.2,
            ),
          ),
          if (member.character.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              member.character,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppType.ui(size: 11, color: AppColors.fg2, height: 1.25),
            ),
          ],
        ],
      ),
    );
  }

  Widget _initialBubble(String initial) {
    return Container(
      color: AppColors.bgSurfaceHi,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: AppType.serif(size: 36, color: AppColors.fg2, height: 1.0),
      ),
    );
  }
}
