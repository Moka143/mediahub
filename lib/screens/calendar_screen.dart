import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/auto_download_event.dart';
import '../providers/auto_download_events_provider.dart';
import '../providers/auto_download_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shows_provider.dart';
import '../services/auto_download_service.dart';
import '../services/tmdb_api_service.dart';
import '../widgets/auto_download_status_card.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/common/status_badge.dart';
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
      for (int seasonNum = (numSeasons - 1).clamp(1, numSeasons); 
           seasonNum <= numSeasons; 
           seasonNum++) {
        if (seasonNum <= 0) continue; // Skip specials

        try {
          final episodes = await tmdbService.getSeasonEpisodes(showId, seasonNum);

          for (final episode in episodes) {
            if (episode.airDate == null) continue;

            final airDate = DateTime.tryParse(episode.airDate!);
            if (airDate == null) continue;

            // Only include episodes within our date range
            if (airDate.isBefore(startDate) || airDate.isAfter(endDate)) {
              continue;
            }

            // Normalize to date only (no time)
            final dateKey = DateTime(airDate.year, airDate.month, airDate.day);

            calendar.putIfAbsent(dateKey, () => []);
            calendar[dateKey]!.add(CalendarEpisode(
              showId: showId,
              showName: show.name,
              posterPath: show.posterPath,
              seasonNumber: episode.seasonNumber,
              episodeNumber: episode.episodeNumber,
              episodeName: episode.name,
              airDate: airDate,
              overview: episode.overview,
            ));
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
final calendarEpisodeDownloadStatusProvider = Provider.family<
    EpisodeDownloadStatus?,
    ({int showId, int season, int episode})>((ref, params) {
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
  DateTime _selectedDate = DateTime.now();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final calendarAsync = ref.watch(calendarEpisodesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: calendarAsync.when(
        loading: () => const LoadingIndicator(message: 'Loading calendar...'),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Failed to load calendar',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => ref.invalidate(calendarEpisodesProvider),
                child: const Text('Retry'),
              ),
            ],
          ),
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

          return _buildCalendarView(context, calendar);
        },
      ),
    );
  }

  Widget _buildCalendarView(
    BuildContext context,
    Map<DateTime, List<CalendarEpisode>> calendar,
  ) {
    final theme = Theme.of(context);

    // Get sorted dates
    final sortedDates = calendar.keys.toList()..sort();

    // Build date sections
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // Auto-download status card
        const SliverToBoxAdapter(
          child: AutoDownloadStatusCard(),
        ),

        // Date navigation header
        SliverToBoxAdapter(
          child: _buildDateNavigator(context, sortedDates, today),
        ),

        // Calendar content
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final date = sortedDates[index];
              final episodes = calendar[date]!;

              return _buildDaySection(context, date, episodes, today);
            },
            childCount: sortedDates.length,
          ),
        ),

        // Activity log section
        SliverToBoxAdapter(
          child: _buildActivityLogSection(context),
        ),

        // Bottom padding
        const SliverPadding(padding: EdgeInsets.only(bottom: AppSpacing.xl)),
      ],
    );
  }

  Widget _buildDateNavigator(
    BuildContext context,
    List<DateTime> dates,
    DateTime today,
  ) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Month/Year header
          Text(
            DateFormat.yMMMM().format(_selectedDate),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // Week day chips
          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 14, // Show 2 weeks
              itemBuilder: (context, index) {
                final date = today.add(Duration(days: index - 3));
                final hasEpisodes = dates.contains(date);
                final isSelected = date.year == _selectedDate.year &&
                    date.month == _selectedDate.month &&
                    date.day == _selectedDate.day;
                final isToday = date == today;

                return Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: _buildDateChip(
                    context,
                    date: date,
                    hasEpisodes: hasEpisodes,
                    isSelected: isSelected,
                    isToday: isToday,
                    onTap: () {
                      setState(() => _selectedDate = date);
                      // Scroll to date if exists
                      final dateIndex = dates.indexOf(date);
                      if (dateIndex >= 0) {
                        _scrollController.animateTo(
                          dateIndex * 200.0, // Approximate card height
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      }
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateChip(
    BuildContext context, {
    required DateTime date,
    required bool hasEpisodes,
    required bool isSelected,
    required bool isToday,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary
              : isToday
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: isToday && !isSelected
              ? Border.all(color: theme.colorScheme.primary, width: 2)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              DateFormat.E().format(date).substring(0, 3),
              style: theme.textTheme.labelSmall?.copyWith(
                color: isSelected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              date.day.toString(),
              style: theme.textTheme.titleMedium?.copyWith(
                color: isSelected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            if (hasEpisodes)
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildDaySection(
    BuildContext context,
    DateTime date,
    List<CalendarEpisode> episodes,
    DateTime today,
  ) {
    final theme = Theme.of(context);
    final isToday = date == today;
    final isPast = date.isBefore(today);

    String dateLabel;
    if (isToday) {
      dateLabel = 'Today';
    } else if (date == today.add(const Duration(days: 1))) {
      dateLabel = 'Tomorrow';
    } else if (date == today.subtract(const Duration(days: 1))) {
      dateLabel = 'Yesterday';
    } else {
      dateLabel = DateFormat.MMMEd().format(date);
    }

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: isToday
                      ? theme.colorScheme.primary
                      : isPast
                          ? theme.colorScheme.surfaceContainerHighest
                          : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  dateLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: isToday
                        ? theme.colorScheme.onPrimary
                        : isPast
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${episodes.length} episode${episodes.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),

          // Episode cards
          ...episodes.map((episode) => _buildEpisodeCard(context, episode, isPast)),
        ],
      ),
    );
  }

  Widget _buildActivityLogSection(BuildContext context) {
    final events = ref.watch(autoDownloadEventsProvider);
    if (events.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final displayEvents = events.take(20).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenPadding,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(
                Icons.history_rounded,
                size: AppIconSize.sm,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Auto-Download Activity',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  ref.read(autoDownloadEventsProvider.notifier).clearEvents();
                },
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ...displayEvents.map((event) {
            final (icon, color) = _eventIcon(event.type);
            final timeAgo = _formatTimeAgo(event.timestamp);

            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      event.message ?? '${event.showName} ${event.episodeCode}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    timeAgo,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withOpacity(0.6),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  (IconData, Color) _eventIcon(AutoDownloadEventType type) {
    return switch (type) {
      AutoDownloadEventType.downloadStarted => (Icons.download_rounded, AppColors.info),
      AutoDownloadEventType.downloadCompleted => (Icons.check_circle_rounded, AppColors.success),
      AutoDownloadEventType.downloadFailed => (Icons.error_rounded, AppColors.error),
      AutoDownloadEventType.torrentNotFound => (Icons.search_off_rounded, AppColors.warning),
      AutoDownloadEventType.episodeQueued => (Icons.queue_rounded, AppColors.info),
      AutoDownloadEventType.checked => (Icons.refresh_rounded, AppColors.info),
    };
  }

  String _formatTimeAgo(DateTime timestamp) {
    final diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _buildEpisodeCard(
    BuildContext context,
    CalendarEpisode episode,
    bool isPast,
  ) {
    final theme = Theme.of(context);

    return Opacity(
      opacity: isPast ? 0.7 : 1.0,
      child: Card(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            // Fetch show details before navigating
            final tmdbService = ref.read(tmdbApiServiceProvider);
            try {
              final show = await tmdbService.getShowDetails(episode.showId);
              if (context.mounted) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ShowDetailsScreen(show: show),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to load show details')),
                );
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                // Show poster
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: episode.posterPath != null
                      ? Image.network(
                          TmdbApiService.getPosterUrl(episode.posterPath!,
                              size: 'w92'),
                          width: 50,
                          height: 75,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _buildPosterPlaceholder(theme),
                        )
                      : _buildPosterPlaceholder(theme),
                ),
                const SizedBox(width: AppSpacing.md),

                // Episode info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Show name
                      Text(
                        episode.showName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),

                      // Episode code, download status, and name
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              episode.episodeCode,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          // Download status badge
                          _buildDownloadStatusBadge(episode),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              episode.displayTitle,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),

                      // Overview preview
                      if (episode.overview != null &&
                          episode.overview!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Text(
                            episode.overview!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withOpacity(0.7),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),

                // Actions
                if (isPast || episode.isToday)
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'download',
                        child: ListTile(
                          leading: Icon(Icons.download_rounded),
                          title: Text('Download Now'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'details',
                        child: ListTile(
                          leading: Icon(Icons.info_outline_rounded),
                          title: Text('Show Details'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'download') {
                        _downloadEpisode(context, episode);
                      } else if (value == 'details') {
                        _navigateToShow(context, episode);
                      }
                    },
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPosterPlaceholder(ThemeData theme) {
    return Container(
      width: 50,
      height: 75,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.tv_rounded,
        color: theme.colorScheme.onSurfaceVariant,
        size: 24,
      ),
    );
  }

  Widget _buildDownloadStatusBadge(CalendarEpisode episode) {
    final status = ref.watch(calendarEpisodeDownloadStatusProvider((
      showId: episode.showId,
      season: episode.seasonNumber,
      episode: episode.episodeNumber,
    )));
    if (status == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      child: switch (status) {
        EpisodeDownloadStatus.downloading =>
          StatusBadge.info(label: 'Downloading', size: StatusBadgeSize.small),
        EpisodeDownloadStatus.downloaded =>
          StatusBadge.success(label: 'Downloaded', size: StatusBadgeSize.small),
        EpisodeDownloadStatus.watched =>
          StatusBadge.success(label: 'Watched', size: StatusBadgeSize.small),
        EpisodeDownloadStatus.awaitingTorrent =>
          StatusBadge.warning(label: 'No Torrent', size: StatusBadgeSize.small),
        EpisodeDownloadStatus.available =>
          StatusBadge.info(label: 'Available', size: StatusBadgeSize.small),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Future<void> _navigateToShow(BuildContext context, CalendarEpisode episode) async {
    final tmdbService = ref.read(tmdbApiServiceProvider);
    try {
      final show = await tmdbService.getShowDetails(episode.showId);
      if (context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ShowDetailsScreen(show: show),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load show details')),
        );
      }
    }
  }

  Future<void> _downloadEpisode(BuildContext context, CalendarEpisode episode) async {
    final tmdbService = ref.read(tmdbApiServiceProvider);
    try {
      final show = await tmdbService.getShowDetails(episode.showId);
      if (show.imdbId == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No IMDB ID found for this show')),
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No torrent found for ${episode.showName} ${episode.episodeCode}')),
          );
        }
        ref.read(autoDownloadEventsProvider.notifier).addEvent(
          AutoDownloadEvent(
            timestamp: DateTime.now(),
            type: AutoDownloadEventType.torrentNotFound,
            showId: episode.showId,
            showName: episode.showName,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            quality: quality,
            message: 'Manual search: no torrent for ${episode.showName} ${episode.episodeCode}',
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success
                  ? 'Downloading ${episode.showName} ${episode.episodeCode}'
                  : 'Failed to start download',
            ),
          ),
        );
      }

      if (success) {
        ref.read(autoDownloadEventsProvider.notifier).addEvent(
          AutoDownloadEvent(
            timestamp: DateTime.now(),
            type: AutoDownloadEventType.downloadStarted,
            showId: episode.showId,
            showName: episode.showName,
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            quality: quality,
            message: 'Manual download: ${episode.showName} ${episode.episodeCode} in $quality',
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }
}
