import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/show.dart';

/// Pill rendered in the show details hero summarising upcoming or
/// recent episode activity.
///
/// Priority:
///   1. `nextEpisode` with a future air date → "S5E3 airs Jan 12"
///      (or "airs today" / "airs tomorrow" for close-in dates).
///   2. `lastEpisode` aired within the last 14 days → "S4E10 aired
///      yesterday" / "aired 3 days ago".
///   3. Returning series with neither → "Returning soon".
///   4. Anything else (finished show, no data) → `SizedBox.shrink`.
///
/// Visual: amber accent strip + mono label + name. Color choice
/// matches the calendar's "live in Nh" pill so the design language
/// is consistent across screens.
class NextEpisodeChip extends StatelessWidget {
  const NextEpisodeChip({super.key, required this.show});

  final Show show;

  @override
  Widget build(BuildContext context) {
    final spec = _resolve(show);
    if (spec == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm - 2,
      ),
      decoration: BoxDecoration(
        color: spec.tint.withAlpha(36),
        border: Border.all(color: spec.tint.withAlpha(0x66), width: 1),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(spec.icon, size: 14, color: spec.tint),
          const SizedBox(width: 6),
          Text(
            spec.kicker,
            style: AppType.mono(
              size: 10,
              color: spec.tint,
              weight: FontWeight.w700,
              letterSpacing: 0.06,
            ),
          ),
          const SizedBox(width: 6),
          Container(width: 1, height: 12, color: spec.tint.withAlpha(0x55)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              spec.label,
              overflow: TextOverflow.ellipsis,
              style: AppType.ui(
                size: 12,
                color: AppColors.fg,
                weight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  _NextChipSpec? _resolve(Show s) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // 1. Upcoming next episode
    final next = s.nextEpisode;
    if (next != null) {
      final airDate = _parse(next.airDate);
      if (airDate != null) {
        final airDay = DateTime(airDate.year, airDate.month, airDate.day);
        final delta = airDay.difference(today).inDays;
        String when;
        if (delta == 0) {
          when = 'airs today';
        } else if (delta == 1) {
          when = 'airs tomorrow';
        } else if (delta > 1 && delta <= 14) {
          when = 'airs in $delta days';
        } else {
          when = 'airs ${DateFormat('MMM d').format(airDate)}';
        }
        return _NextChipSpec(
          icon: Icons.schedule_rounded,
          kicker: next.episodeCode,
          label: '${next.name} · $when',
          tint: AppColors.accentAmber,
        );
      }
    }

    // 2. Recently aired last episode (within last 14 days)
    final last = s.lastEpisode;
    if (last != null) {
      final airDate = _parse(last.airDate);
      if (airDate != null) {
        final airDay = DateTime(airDate.year, airDate.month, airDate.day);
        final delta = today.difference(airDay).inDays;
        if (delta >= 0 && delta <= 14) {
          String when;
          if (delta == 0) {
            when = 'aired today';
          } else if (delta == 1) {
            when = 'aired yesterday';
          } else {
            when = 'aired $delta days ago';
          }
          return _NextChipSpec(
            icon: Icons.check_circle_outline_rounded,
            kicker: last.episodeCode,
            label: '${last.name} · $when',
            tint: AppColors.accent,
          );
        }
      }
    }

    // 3. Returning series with no announced next episode
    if (s.isAiring) {
      return const _NextChipSpec(
        icon: Icons.autorenew_rounded,
        kicker: 'NEXT EP',
        label: 'Returning soon',
        tint: AppColors.accentAmber,
      );
    }

    return null;
  }

  DateTime? _parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}

class _NextChipSpec {
  const _NextChipSpec({
    required this.icon,
    required this.kicker,
    required this.label,
    required this.tint,
  });

  final IconData icon;
  final String kicker;
  final String label;
  final Color tint;
}
