import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../widgets/editorial/editorial.dart';
import '../models/auto_download_event.dart';
import '../providers/auto_download_events_provider.dart';
import '../providers/auto_download_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shows_provider.dart';
import '../services/auto_download_service.dart';
import '../utils/feedback_utils.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import 'show_details_screen.dart';

/// Model for calendar episode with additional date information
class CalendarEpisode {
  final int showId;
  final String showName;
  final String? posterPath;
  final int seasonNumber;
  final int episodeNumber;
  final String? episodeName;
  final DateTime airDate;
  final String? overview;

  CalendarEpisode({
    required this.showId,
    required this.showName,
    this.posterPath,
    required this.seasonNumber,
    required this.episodeNumber,
    this.episodeName,
    required this.airDate,
    this.overview,
  });

  String get episodeCode =>
      'S${seasonNumber.toString().padLeft(2, '0')}E${episodeNumber.toString().padLeft(2, '0')}';

  String get displayTitle => episodeName ?? 'Episode $episodeNumber';

  bool get isToday {
    final now = DateTime.now();
    return airDate.year == now.year &&
        airDate.month == now.month &&
        airDate.day == now.day;
  }

  bool get isPast => airDate.isBefore(DateTime.now());

  bool get isFuture => airDate.isAfter(DateTime.now());
}

/// Provider for calendar episodes from favorite shows
final calendarEpisodesProvider =
    FutureProvider<Map<DateTime, List<CalendarEpisode>>>((ref) async {
      final favorites = ref.watch(favoritesProvider);
      final tmdbService = ref.watch(tmdbApiServiceProvider);

      if (favorites.favoriteIds.isEmpty || !tmdbService.isConfigured) return {};

      final Map<DateTime, List<CalendarEpisode>> calendar = {};

      // Date range: 7 days ago to 30 days in future
      final startDate = DateTime.now().subtract(const Duration(days: 7));
      final endDate = DateTime.now().add(const Duration(days: 30));

      for (final showId in favorites.favoriteIds) {
        try {
          // Get show details for name and poster
          final show = await tmdbService.getShowDetails(showId);
          final numSeasons = show.numberOfSeasons ?? 0;

          // Get episodes from recent seasons (last 2 seasons to limit API calls)
          for (
            int seasonNum = (numSeasons - 1).clamp(1, numSeasons);
            seasonNum <= numSeasons;
            seasonNum++
          ) {
            if (seasonNum <= 0) continue; // Skip specials

            try {
              final episodes = await tmdbService.getSeasonEpisodes(
                showId,
                seasonNum,
              );

              for (final episode in episodes) {
                if (episode.airDate == null) continue;

                final airDate = DateTime.tryParse(episode.airDate!);
                if (airDate == null) continue;

                // Only include episodes within our date range
                if (airDate.isBefore(startDate) || airDate.isAfter(endDate)) {
                  continue;
                }

                // Normalize to date only (no time)
                final dateKey = DateTime(
                  airDate.year,
                  airDate.month,
                  airDate.day,
                );

                calendar.putIfAbsent(dateKey, () => []);
                calendar[dateKey]!.add(
                  CalendarEpisode(
                    showId: showId,
                    showName: show.name,
                    posterPath: show.posterPath,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber,
                    episodeName: episode.name,
                    airDate: airDate,
                    overview: episode.overview,
                  ),
                );
              }
            } catch (e) {
              // Skip seasons that fail to load
            }
          }
        } catch (e) {
          // Skip shows that fail to load
        }
      }

      // Sort episodes within each day
      for (final episodes in calendar.values) {
        episodes.sort((a, b) {
          // Sort by show name, then by episode
          final showCompare = a.showName.compareTo(b.showName);
          if (showCompare != 0) return showCompare;
          return a.episodeCode.compareTo(b.episodeCode);
        });
      }

      return calendar;
    });

/// Provider for today's episodes count (for badges)
final todayEpisodesCountProvider = Provider<int>((ref) {
  final calendarAsync = ref.watch(calendarEpisodesProvider);
  final calendar = calendarAsync.value ?? {};

  final today = DateTime.now();
  final todayKey = DateTime(today.year, today.month, today.day);

  return calendar[todayKey]?.length ?? 0;
});

/// Provider for upcoming episodes count (next 7 days)
final upcomingEpisodesCountProvider = Provider<int>((ref) {
  final calendarAsync = ref.watch(calendarEpisodesProvider);
  final calendar = calendarAsync.value ?? {};

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final weekFromNow = today.add(const Duration(days: 7));

  int count = 0;
  for (final entry in calendar.entries) {
    if (entry.key.isAfter(today.subtract(const Duration(days: 1))) &&
        entry.key.isBefore(weekFromNow)) {
      count += entry.value.length;
    }
  }
  return count;
});

/// Download status for a calendar episode, cross-referencing auto-download tracking
final calendarEpisodeDownloadStatusProvider =
    Provider.family<
      EpisodeDownloadStatus?,
      ({int showId, int season, int episode})
    >((ref, params) {
      final autoState = ref.watch(autoDownloadProvider);
      final tracking = autoState.lastDownloadedEpisodes[params.showId];
      if (tracking != null &&
          tracking.season == params.season &&
          tracking.episode == params.episode) {
        return tracking.status;
      }
      // Check download queue
      final queueKey =
          '${params.showId}_S${params.season.toString().padLeft(2, '0')}E${params.episode.toString().padLeft(2, '0')}';
      if (autoState.downloadQueue.contains(queueKey)) {
        return EpisodeDownloadStatus.downloading;
      }
      return null;
    });

// ============================================================================
// Calendar Screen
// ============================================================================

/// Screen showing upcoming episodes from favorite shows in a calendar format
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calendarAsync = ref.watch(calendarEpisodesProvider);
    return calendarAsync.when(
      loading: () => const LoadingIndicator(message: 'Loading calendar...'),
      error: (e, _) => EmptyState.error(
        message: 'Failed to load calendar',
        onRetry: () => ref.invalidate(calendarEpisodesProvider),
      ),
      data: (calendar) {
        if (calendar.isEmpty) {
          return const EmptyState(
            icon: Icons.calendar_month_outlined,
            title: 'No upcoming episodes',
            subtitle:
                'Add shows to your favorites to see upcoming episodes here',
          );
        }

        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        // Anchor the strip on yesterday + today + the next 5 days. The
        // calendar's job is to surface UPCOMING episodes, so dedicating
        // most of the columns to forward-dates is more useful than the
        // ISO-week strip we used before — which on Sunday hid the entire
        // following week behind a "next week" jump.
        const lookback = 1;
        final weekStart = today.subtract(const Duration(days: lookback));
        final weekDays = List.generate(
          7,
          (i) => weekStart.add(Duration(days: i)),
        );

        final airingThisWeek = <CalendarEpisode>[];
        for (final d in weekDays) {
          airingThisWeek.addAll(calendar[d] ?? const []);
        }
        airingThisWeek.sort((a, b) => a.airDate.compareTo(b.airDate));

        return SingleChildScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CalendarWeekHeader(
                weekStart: weekStart,
                airingCount: airingThisWeek.length,
              ),
              const SizedBox(height: AppSpacing.lg),
              _WeekStrip(
                weekDays: weekDays,
                today: today,
                calendar: calendar,
                onEpisodeTap: (e) => _navigateToShow(context, e),
              ),
              const SizedBox(height: AppSpacing.xxl),
              const _AiringHeader(),
              const SizedBox(height: AppSpacing.md),
              if (airingThisWeek.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.huge),
                  child: Center(
                    child: Text(
                      'Nothing airing this week.',
                      style: TextStyle(color: AppColors.fg2),
                    ),
                  ),
                )
              else
                Column(
                  children: [
                    for (final ep in airingThisWeek)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _AiringRow(
                          episode: ep,
                          today: today,
                          onTap: () => _navigateToShow(context, ep),
                          onAutoGrab: () => _downloadEpisode(context, ep),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _navigateToShow(
    BuildContext context,
    CalendarEpisode episode,
  ) async {
    final tmdbService = ref.read(tmdbApiServiceProvider);
    try {
      final show = await tmdbService.getShowDetails(episode.showId);
      if (context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ShowDetailsScreen(show: show)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppSnackBar.showError(context, message: 'Failed to load show details');
      }
    }
  }

  Future<void> _downloadEpisode(
    BuildContext context,
    CalendarEpisode episode,
  ) async {
    final tmdbService = ref.read(tmdbApiServiceProvider);
    try {
      final show = await tmdbService.getShowDetails(episode.showId);
      if (show.imdbId == null) {
        if (context.mounted) {
          AppSnackBar.showError(
            context,
            message: 'No IMDB ID found for this show',
          );
        }
        return;
      }

      final service = ref.read(autoDownloadServiceProvider);
      final quality = ref.read(autoDownloadProvider).defaultQuality;

      final torrent = await service.findTorrentForEpisode(
        imdbId: show.imdbId!,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
        preferredQuality: quality,
      );

      if (torrent == null) {
        if (context.mounted) {
          AppSnackBar.showInfo(
            context,
            message:
                'No torrent found for ${episode.showName} ${episode.episodeCode}',
          );
        }
        ref
            .read(autoDownloadEventsProvider.notifier)
            .addEvent(
              AutoDownloadEvent(
                timestamp: DateTime.now(),
                type: AutoDownloadEventType.torrentNotFound,
                showId: episode.showId,
                showName: episode.showName,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                quality: quality,
                message:
                    'Manual search: no torrent for ${episode.showName} ${episode.episodeCode}',
              ),
            );
        return;
      }

      final settings = ref.read(settingsProvider);
      final success = await service.downloadNextEpisode(
        magnetLink: torrent.magnetUrl,
        savePath: settings.defaultSavePath,
        infoHash: torrent.hash,
        fileIdx: torrent.fileIdx,
      );

      if (context.mounted) {
        if (success) {
          AppSnackBar.showSuccess(
            context,
            message: 'Downloading ${episode.showName} ${episode.episodeCode}',
          );
        } else {
          AppSnackBar.showError(context, message: 'Failed to start download');
        }
      }

      if (success) {
        ref
            .read(autoDownloadEventsProvider.notifier)
            .addEvent(
              AutoDownloadEvent(
                timestamp: DateTime.now(),
                type: AutoDownloadEventType.downloadStarted,
                showId: episode.showId,
                showName: episode.showName,
                season: episode.seasonNumber,
                episode: episode.episodeNumber,
                quality: quality,
                message:
                    'Manual download: ${episode.showName} ${episode.episodeCode} in $quality',
              ),
            );
      }
    } catch (e) {
      if (context.mounted) {
        AppSnackBar.showError(context, message: 'Download failed: $e');
      }
    }
  }
}

// ============================================================================
// MediaHub calendar layout — week header + 7-column week strip + airing feed
// ============================================================================

class _CalendarWeekHeader extends StatelessWidget {
  const _CalendarWeekHeader({
    required this.weekStart,
    required this.airingCount,
  });

  final DateTime weekStart;
  final int airingCount;

  @override
  Widget build(BuildContext context) {
    final end = weekStart.add(const Duration(days: 6));
    final startMonth = DateFormat('MMMM').format(weekStart);
    final endMonth = DateFormat('MMMM').format(end);
    final range = startMonth == endMonth
        ? '${DateFormat('MMMM d').format(weekStart)} – ${end.day}, ${end.year}'
        : '${DateFormat('MMM d').format(weekStart)} – ${DateFormat('MMM d').format(end)}, ${end.year}';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SerifTitle(range, size: 48, height: 1.0, letterSpacing: -0.01),
              const SizedBox(height: 6),
              MonoLabel(
                airingCount == 1
                    ? 'NEXT 7 DAYS · 1 AIRING'
                    : 'NEXT 7 DAYS · $airingCount AIRING',
                color: AppColors.fg2,
                letterSpacing: 0.1,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.weekDays,
    required this.today,
    required this.calendar,
    required this.onEpisodeTap,
  });

  final List<DateTime> weekDays;
  final DateTime today;
  final Map<DateTime, List<CalendarEpisode>> calendar;
  final ValueChanged<CalendarEpisode> onEpisodeTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final colWidth = (c.maxWidth - AppSpacing.sm * 6) / 7;
        return Row(
          children: [
            for (var i = 0; i < weekDays.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: colWidth,
                child: _WeekColumn(
                  date: weekDays[i],
                  isToday: weekDays[i] == today,
                  episodes: calendar[weekDays[i]] ?? const [],
                  onEpisodeTap: onEpisodeTap,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _WeekColumn extends StatelessWidget {
  const _WeekColumn({
    required this.date,
    required this.isToday,
    required this.episodes,
    required this.onEpisodeTap,
  });

  final DateTime date;
  final bool isToday;
  final List<CalendarEpisode> episodes;
  final ValueChanged<CalendarEpisode> onEpisodeTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 220),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isToday
            ? AppColors.seedColor.withAlpha(36)
            : AppColors.bgSurface,
        border: Border.all(
          color: isToday ? AppColors.seedColor.withAlpha(0x66) : AppColors.line,
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              MonoLabel(
                DateFormat('E').format(date).toUpperCase(),
                color: isToday ? AppColors.accent : AppColors.fg3,
                letterSpacing: 0.14,
              ),
              const Spacer(),
              SerifTitle(
                '${date.day}',
                size: 36,
                height: 1.0,
                color: isToday ? AppColors.accent : AppColors.fg,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          for (final e in episodes.take(3)) ...[
            _DayEpisodeChip(episode: e, onTap: () => onEpisodeTap(e)),
            const SizedBox(height: AppSpacing.xs),
          ],
          if (episodes.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '+${episodes.length - 3} more',
                style: AppType.mono(size: 10, color: AppColors.fg2),
              ),
            ),
        ],
      ),
    );
  }
}

class _DayEpisodeChip extends StatelessWidget {
  const _DayEpisodeChip({required this.episode, required this.onTap});

  final CalendarEpisode episode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hue = episode.showName.codeUnits.fold<int>(0, (a, b) => a + b) % 360;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              HSLColor.fromAHSL(0.6, hue.toDouble(), 0.6, 0.3).toColor(),
              HSLColor.fromAHSL(
                0.6,
                hue.toDouble() + 30 % 360,
                0.5,
                0.18,
              ).toColor(),
            ],
          ),
          border: Border.all(
            color: HSLColor.fromAHSL(0.4, hue.toDouble(), 0.6, 0.5).toColor(),
          ),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MonoLabel(
              episode.episodeCode,
              color: AppColors.accent,
              letterSpacing: 0.12,
              maxLines: 1,
            ),
            const SizedBox(height: 4),
            Text(
              episode.showName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.ui(
                size: 12,
                color: AppColors.fg,
                weight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AiringHeader extends StatelessWidget {
  const _AiringHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: const [
        SerifTitle('Airing this week', size: 22, height: 1.0),
        SizedBox(width: 12),
        MonoLabel('AUTO-GRAB', color: AppColors.fg3, letterSpacing: 0.14),
      ],
    );
  }
}

class _AiringRow extends StatelessWidget {
  const _AiringRow({
    required this.episode,
    required this.today,
    required this.onTap,
    required this.onAutoGrab,
  });

  final CalendarEpisode episode;
  final DateTime today;
  final VoidCallback onTap;
  final VoidCallback onAutoGrab;

  @override
  Widget build(BuildContext context) {
    final hue = episode.showName.codeUnits.fold<int>(0, (a, b) => a + b) % 360;
    final airDate = DateTime(
      episode.airDate.year,
      episode.airDate.month,
      episode.airDate.day,
    );
    final isToday = airDate == today;
    final inHours = episode.airDate.difference(DateTime.now()).inHours;
    final isLive = isToday && inHours >= 0 && inHours < 8;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          border: Border.all(
            color: isLive
                ? AppColors.accentAmber.withAlpha(0x66)
                : AppColors.line,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            // Date column
            SizedBox(
              width: 70,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat('E').format(airDate).toUpperCase(),
                    style: AppType.mono(
                      size: 10,
                      color: AppColors.fg2,
                      weight: FontWeight.w700,
                      letterSpacing: 0.066,
                    ),
                  ),
                  Text(
                    DateFormat('MMM d').format(airDate).toUpperCase(),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.fg,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            // Poster thumbnail — real TMDB art when we have a path,
            // hue gradient fallback otherwise.
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 40,
                height: 60,
                child:
                    episode.posterPath != null && episode.posterPath!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl:
                            'https://image.tmdb.org/t/p/w185${episode.posterPath}',
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => _gradientPoster(hue),
                        placeholder: (_, _) => _gradientPoster(hue),
                      )
                    : _gradientPoster(hue),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            // Title + meta
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    episode.showName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${episode.episodeCode} · ${DateFormat('h:mm a').format(episode.airDate)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono(size: 11, color: AppColors.fg2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            // Status pill
            isLive
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accentAmber.withAlpha(36),
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    child: Text(
                      '● LIVE IN ${inHours.clamp(1, 99)}H',
                      style: AppType.mono(
                        size: 10,
                        color: AppColors.accentAmber,
                        weight: FontWeight.w700,
                        letterSpacing: 0.05,
                      ),
                    ),
                  )
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(AppOpacity.subtle),
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                    child: Text(
                      'SCHEDULED',
                      style: AppType.mono(
                        size: 10,
                        color: AppColors.fg2,
                        weight: FontWeight.w700,
                        letterSpacing: 0.05,
                      ),
                    ),
                  ),
            const SizedBox(width: AppSpacing.sm),
            // AUTO-GRAB button
            GestureDetector(
              onTap: onAutoGrab,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppColors.seedColor,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_rounded,
                      size: 11,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'AUTO-GRAB',
                      style: AppType.mono(
                        size: 11,
                        color: Colors.white,
                        weight: FontWeight.w700,
                        letterSpacing: 0.05,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact gradient placeholder used when an episode has no poster
/// path (or while the network image is loading). Hue is derived
/// from the show name so each title looks distinct.
Widget _gradientPoster(int hue) {
  return DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          HSLColor.fromAHSL(1, hue.toDouble(), 0.6, 0.4).toColor(),
          HSLColor.fromAHSL(1, (hue + 30) % 360, 0.55, 0.2).toColor(),
        ],
      ),
    ),
  );
}
