import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../design/app_colors.dart';
import '../../design/app_tokens.dart';
import '../../design/app_typography.dart';
import '../../models/episode.dart';
import '../../models/show.dart';
import '../../utils/formatters.dart';
import '../editorial/editorial_badge.dart';

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
/// Visual: amber accent strip + mono label + name, matching the
/// calendar's "airs today" pill.
class NextEpisodeChip extends StatelessWidget {
  const NextEpisodeChip({super.key, required this.show, this.now});

  final Show show;

  /// The current time, for tests. Defaults to the clock.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final spec = _resolve(show);
    if (spec == null) return const SizedBox.shrink();

    return Container(
      padding: EditorialBadge.prominentPadding,
      decoration: BoxDecoration(
        color: spec.tint.withAlpha(AppOpacity.light),
        border: Border.all(
          color: spec.tint.withAlpha(AppOpacity.semi),
          width: 1,
        ),
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
              size: AppType.sizeLabel,
              color: spec.tint,
              weight: FontWeight.w700,
              letterSpacing: 0.06,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 1,
            height: 12,
            color: spec.tint.withValues(alpha: 0.33),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              spec.label,
              overflow: TextOverflow.ellipsis,
              style: AppType.ui(
                size: AppType.sizeCaption,
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
    final today = now ?? DateTime.now();

    // 1. Upcoming next episode.
    //
    // Guarded on the date actually being in the future. TMDB's
    // `next_episode_to_air` goes stale — it keeps naming an episode after it
    // has aired, and the app caches show details on top of that — so an
    // unguarded branch rendered "airs Jul 8" in September, in the future
    // tense, months after the fact. A past date falls through to the
    // recently-aired branch below, which describes it correctly.
    final next = s.nextEpisode;
    if (next != null) {
      final airDate = parseAirDate(next.airDate);
      if (airDate != null) {
        // Calendar days, not `difference().inDays` between local midnights:
        // across the spring DST change those come up a day short, and the
        // chip said "airs today" about tomorrow.
        final delta = Formatters.calendarDaysBetween(today, airDate);
        if (delta < 0) return _resolveAired(s, today);
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
          tint: AppColors.warn,
        );
      }
    }

    return _resolveAired(s, today);
  }

  /// The already-aired half: a recent last episode, or a returning series
  /// with nothing announced. Split out so the upcoming branch can hand over
  /// to it when TMDB's "next" episode turns out to be in the past.
  _NextChipSpec? _resolveAired(Show s, DateTime today) {
    // 2. Recently aired last episode (within last 14 days)
    final last = s.lastEpisode;
    if (last != null) {
      final airDate = parseAirDate(last.airDate);
      if (airDate != null) {
        final delta = Formatters.calendarDaysBetween(airDate, today);
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
        tint: AppColors.warn,
      );
    }

    return null;
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
