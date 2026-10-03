import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../app.dart';
import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/show.dart';
import '../providers/auto_download_provider.dart';
import '../providers/calendar_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../services/app_logger.dart';
import '../services/auto_download_service.dart';
import '../utils/error_messages.dart';
import '../utils/feedback_utils.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/hub_pressable.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/editorial/editorial.dart';
import '../widgets/episodes/episode_status.dart';
import '../widgets/media/hue_backdrop.dart';
import '../widgets/media/row_header.dart';
import 'settings_screen.dart';
import 'show_details_screen.dart';

/// When an episode airs, relative to [today], in calendar days.
///
/// Date only: TMDB air dates carry no time, which is why every row used to
/// read "12:00 AM", and why "Airs today" is as precise as it can honestly
/// get. An episode dated in the past says so — yesterday's episodes used to
/// read "Scheduled".
String calendarTimingLabel(CalendarEpisode episode, DateTime today) {
  final days = episode.daysFrom(today);
  if (days < -1) return 'Aired';
  if (days == -1) return 'Aired yesterday';
  if (days == 0) return 'Airs today';
  if (days == 1) return 'Tomorrow';
  return 'In $days days';
}

/// The strip's date range as a heading — "October 3 – 9, 2026", or
/// "Sep 29 – Oct 5, 2026" across a month boundary.
String calendarRangeLabel(DateTime start, {int days = 7}) {
  final end = start.add(Duration(days: days - 1));
  if (start.month == end.month && start.year == end.year) {
    return '${DateFormat('MMMM d').format(start)} – ${end.day}, ${end.year}';
  }
  return '${DateFormat('MMM d').format(start)} – '
      '${DateFormat('MMM d').format(end)}, ${end.year}';
}

/// The two stops of an episode chip's gradient. The second is 30° round the
/// wheel — `(hue + 30) % 360`; it used to be written `hue + 30 % 360`,
/// which is `hue + 30`, and handed HSL hues past 360.
List<Color> calendarChipGradient(double hue) => [
  HSLColor.fromAHSL(0.6, hue % 360, 0.6, 0.3).toColor(),
  HSLColor.fromAHSL(0.6, (hue + 30) % 360, 0.5, 0.18).toColor(),
];

/// Upcoming and recent episodes from the user's favourite shows.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  final ScrollController _scrollController = ScrollController();

  /// Episodes with a download request in flight. A second click on the same
  /// row used to start a second search and add the torrent twice.
  final Set<CalendarEpisode> _busy = {};

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _openSettings() => unawaited(
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
  );

  /// The show page loads the full record itself, so this opens at once —
  /// it used to wait on a details request first, and fail with a toast
  /// when offline.
  void _openShow(CalendarEpisode episode) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ShowDetailsScreen(
            show: Show(
              id: episode.showId,
              name: episode.showName,
              posterPath: episode.posterPath,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _download(CalendarEpisode episode) async {
    if (_busy.contains(episode)) return;
    setState(() => _busy.add(episode));
    // The same queue, tracking and duplicate checks automatic downloads go
    // through. This used to be a private copy of the search-and-add with
    // none of them — and a details call without the IMDb id it needed, so
    // it failed every time.
    final notifier = ref.read(autoDownloadProvider.notifier);
    final container = ProviderScope.containerOf(context, listen: false);
    EpisodeGrabResult? result;
    try {
      result = await notifier.downloadEpisodeNow(
        showId: episode.showId,
        showName: episode.showName,
        imdbId: episode.imdbId,
        season: episode.seasonNumber,
        episode: episode.episodeNumber,
      );
    } catch (e) {
      AppLog.w('[Calendar] download of ${episode.episodeCode} failed: $e');
    }
    if (!mounted) return;
    setState(() => _busy.remove(episode));

    if (result == null) {
      AppSnackBar.showError(
        context,
        message:
            "Couldn't start the download for ${episode.showName} "
            '${episode.episodeCode}.',
      );
      return;
    }
    if (result.ok) {
      AppSnackBar.showSuccess(
        context,
        message: result.message,
        actionLabel: 'Open Transfers',
        onAction: () {
          container
              .read(currentTabIndexProvider.notifier)
              .show(AppTab.transfers);
          rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
        },
      );
    } else {
      AppSnackBar.showWarning(context, message: result.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(calendarEpisodesProvider);
    final data = async.value;
    if (data == null) {
      if (async.hasError) {
        return EmptyState.error(
          title: "Couldn't load your calendar",
          message: friendlyErrorMessage(async.error!, subject: 'your shows'),
          onRetry: () => ref.invalidate(calendarEpisodesProvider),
        );
      }
      return const LoadingIndicator(message: 'Loading your calendar…');
    }

    if (data.showCount == 0) {
      return EmptyState(
        icon: Icons.calendar_month_outlined,
        title: 'No favorite shows yet',
        subtitle: 'Favorite a show and its episodes appear here as they air.',
        action: EditorialButton(
          label: 'Browse shows',
          icon: Icons.explore_rounded,
          kind: EditorialButtonKind.accent,
          onPressed: () =>
              ref.read(currentTabIndexProvider.notifier).show(AppTab.shows),
        ),
      );
    }
    if (!data.tmdbConfigured) {
      return EmptyState(
        icon: Icons.key_off_rounded,
        title: 'The calendar needs a TMDB token',
        subtitle: 'Add your TMDB token in Settings to see when your shows air.',
        action: EditorialButton(
          label: 'Open Settings',
          kind: EditorialButtonKind.accent,
          onPressed: _openSettings,
        ),
      );
    }
    if (data.allFailed) {
      final error = data.failures.first.error;
      final needsSettings = failureNeedsSettings(error);
      return EmptyState.error(
        title: "Couldn't load your calendar",
        message: friendlyErrorMessage(error, subject: 'your shows'),
        onRetry: () => ref.invalidate(calendarEpisodesProvider),
        secondaryLabel: needsSettings ? 'Open Settings' : null,
        onSecondary: needsSettings ? _openSettings : null,
      );
    }

    return _CalendarPage(
      data: data,
      today: dateOnly(DateTime.now()),
      scrollController: _scrollController,
      busy: _busy,
      onOpenShow: _openShow,
      onDownload: (e) => unawaited(_download(e)),
      onRetry: () => ref.invalidate(calendarEpisodesProvider),
    );
  }
}

class _CalendarPage extends StatelessWidget {
  const _CalendarPage({
    required this.data,
    required this.today,
    required this.scrollController,
    required this.busy,
    required this.onOpenShow,
    required this.onDownload,
    required this.onRetry,
  });

  final CalendarData data;
  final DateTime today;
  final ScrollController scrollController;
  final Set<CalendarEpisode> busy;
  final ValueChanged<CalendarEpisode> onOpenShow;
  final ValueChanged<CalendarEpisode> onDownload;
  final VoidCallback onRetry;

  /// The date range is the page's headline — larger than the type ramp's
  /// top step, [AppType.sizeDisplay].
  static const double _headlineSize = 48;

  @override
  Widget build(BuildContext context) {
    // The strip is today and the six days after it — what the header says.
    // It used to start yesterday under a "NEXT 7 DAYS" heading.
    final weekDays = List.generate(7, (i) => today.add(Duration(days: i)));
    final thisWeek = data.between(weekDays.first, weekDays.last);
    final comingUp = data.between(
      today,
      today.add(const Duration(days: calendarLookaheadDays)),
    );
    final recentlyAired = data.between(
      today.subtract(const Duration(days: calendarLookbackDays)),
      today.subtract(const Duration(days: 1)),
    );

    Widget row(CalendarEpisode e) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: _AiringRow(
        episode: e,
        today: today,
        busy: busy.contains(e),
        onTap: () => onOpenShow(e),
        onDownload: () => onDownload(e),
      ),
    );

    return SingleChildScrollView(
      controller: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SerifTitle(
            calendarRangeLabel(today),
            size: _headlineSize,
            height: 1.0,
            letterSpacing: -0.01,
          ),
          const SizedBox(height: 6),
          MonoLabel(
            'Next 7 days · '
            '${thisWeek.length == 1 ? '1 episode' : '${thisWeek.length} episodes'}',
            color: AppColors.fg2,
            letterSpacing: 0.1,
          ),
          if (data.failures.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _PartialFailureBanner(
              failed: data.failures.length,
              total: data.showCount,
              onRetry: onRetry,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _WeekStrip(
            weekDays: weekDays,
            today: today,
            data: data,
            onEpisodeTap: onOpenShow,
          ),
          const SizedBox(height: AppSpacing.xxl),
          const RowHeader(title: 'Coming up', size: AppType.sizeTitle),
          const SizedBox(height: AppSpacing.md),
          if (comingUp.isEmpty)
            _NothingComingUp(
              showCount: data.showCount,
              next: data.nextAfterWindow,
            )
          else
            Column(children: [for (final e in comingUp) row(e)]),
          if (recentlyAired.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xxl),
            RowHeader(
              title: 'Recently aired',
              note: 'Last $calendarLookbackDays days',
              size: AppType.sizeTitle,
            ),
            const SizedBox(height: AppSpacing.md),
            Column(children: [for (final e in recentlyAired.reversed) row(e)]),
          ],
        ],
      ),
    );
  }
}

/// Some favourite shows failed to load: the page shows the rest, and says
/// so — a missing show must not read as "nothing airing".
class _PartialFailureBanner extends StatelessWidget {
  const _PartialFailureBanner({
    required this.failed,
    required this.total,
    required this.onRetry,
  });

  final int failed;
  final int total;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.warn.withAlpha(AppOpacity.subtle),
        border: Border.all(color: AppColors.warn.withValues(alpha: 0.33)),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.warn,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              "Couldn't load $failed of your $total shows, so some episodes "
              'may be missing.',
              style: AppType.caption(color: AppColors.fg1),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

/// Nothing dated in the next 30 days — said as exactly that, with the next
/// known date when there is one. It used to tell people with favourites to
/// "add shows to your favorites".
class _NothingComingUp extends StatelessWidget {
  const _NothingComingUp({required this.showCount, required this.next});

  final int showCount;
  final CalendarEpisode? next;

  @override
  Widget build(BuildContext context) {
    final shows = showCount == 1 ? 'your 1 show' : 'your $showCount shows';
    final upcoming = next;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nothing airing in the next $calendarLookaheadDays days from '
            '$shows.',
            style: AppType.ui(size: AppType.sizeLead, color: AppColors.fg1),
          ),
          if (upcoming != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Next up: ${upcoming.showName} ${upcoming.episodeCode} on '
              '${DateFormat('EEEE, MMMM d, y').format(upcoming.airDate)}.',
              style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg2),
            ),
          ],
        ],
      ),
    );
  }
}

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.weekDays,
    required this.today,
    required this.data,
    required this.onEpisodeTap,
  });

  final List<DateTime> weekDays;
  final DateTime today;
  final CalendarData data;
  final ValueChanged<CalendarEpisode> onEpisodeTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final colWidth = (c.maxWidth - AppSpacing.sm * 6) / 7;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < weekDays.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: colWidth,
                child: _WeekColumn(
                  date: weekDays[i],
                  isToday: weekDays[i] == today,
                  episodes: data.on(weekDays[i]),
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
        color: isToday ? AppColors.accentSoft : AppColors.bgSurface,
        border: Border.all(
          color: isToday
              ? AppColors.accent.withAlpha(AppOpacity.semi)
              : AppColors.line,
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
                DateFormat('E').format(date),
                color: isToday ? AppColors.accent : AppColors.fg2,
                letterSpacing: 0.14,
              ),
              const Spacer(),
              SerifTitle(
                '${date.day}',
                size: AppType.sizeHeadline,
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
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: Text(
                '+${episodes.length - 3} more',
                style: AppType.mono(
                  size: AppType.sizeLabel,
                  color: AppColors.fg2,
                ),
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
    final hue = hueForText(episode.showName);
    return HubPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xs),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: calendarChipGradient(hue),
          ),
          border: Border.all(
            color: HSLColor.fromAHSL(0.4, hue, 0.6, 0.5).toColor(),
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
                size: AppType.sizeCaption,
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

/// One episode in the Coming up / Recently aired lists. The row opens the
/// show; the button on the right downloads the episode.
class _AiringRow extends StatefulWidget {
  const _AiringRow({
    required this.episode,
    required this.today,
    required this.busy,
    required this.onTap,
    required this.onDownload,
  });

  final CalendarEpisode episode;
  final DateTime today;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onDownload;

  @override
  State<_AiringRow> createState() => _AiringRowState();
}

class _AiringRowState extends State<_AiringRow> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.episode;
    final hue = hueForText(e.showName);
    final isToday = e.daysFrom(widget.today) == 0;

    return HubPressable(
      onTap: widget.onTap,
      onHoverChanged: (h) => setState(() => _active = h),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: _active ? AppColors.bgSurfaceHi : AppColors.bgSurface,
          border: Border.all(
            color: isToday
                ? AppColors.warn.withAlpha(AppOpacity.semi)
                : AppColors.line,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DateFormat('E').format(e.airDate).toUpperCase(),
                    style: AppType.mono(
                      size: AppType.sizeLabel,
                      color: AppColors.fg2,
                      weight: FontWeight.w700,
                      letterSpacing: 0.066,
                    ),
                  ),
                  Text(
                    DateFormat('MMM d').format(e.airDate),
                    style: AppType.ui(
                      size: AppType.sizeSubhead,
                      weight: FontWeight.w700,
                      color: AppColors.fg,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 40,
                height: 60,
                child: e.posterPath != null && e.posterPath!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl:
                            'https://image.tmdb.org/t/p/w185${e.posterPath}',
                        fit: BoxFit.cover,
                        memCacheWidth: 120,
                        errorWidget: (_, _, _) => HueBackdrop(hue: hue),
                        placeholder: (_, _) => HueBackdrop(hue: hue),
                      )
                    : HueBackdrop(hue: hue),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.showName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      size: AppType.sizeBody,
                      weight: FontWeight.w600,
                      color: AppColors.fg,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      e.episodeCode,
                      if (e.episodeName != null && e.episodeName!.isNotEmpty)
                        e.episodeName!,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono(
                      size: AppType.sizeSmall,
                      color: AppColors.fg2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            _TimingPill(
              label: calendarTimingLabel(e, widget.today),
              highlight: isToday,
            ),
            const SizedBox(width: AppSpacing.sm),
            _DownloadControl(
              episode: e,
              today: widget.today,
              busy: widget.busy,
              onDownload: widget.onDownload,
            ),
          ],
        ),
      ),
    );
  }
}

class _TimingPill extends StatelessWidget {
  const _TimingPill({required this.label, required this.highlight});

  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final color = highlight ? AppColors.warn : AppColors.fg2;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: highlight
            ? AppColors.warn.withAlpha(AppOpacity.light)
            : AppColors.glassFill,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        label,
        style: AppType.ui(
          size: AppType.sizeSmall,
          color: color,
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The Download button, or what already happened to the episode.
///
/// Watches Transfers, automatic-download tracking and the library, so a
/// download started here — or by auto-download — shows on its row instead
/// of inviting a second one.
class _DownloadControl extends ConsumerWidget {
  const _DownloadControl({
    required this.episode,
    required this.today,
    required this.busy,
    required this.onDownload,
  });

  final CalendarEpisode episode;
  final DateTime today;
  final bool busy;
  final VoidCallback onDownload;

  EpisodeStatus _status(WidgetRef ref) {
    final e = episode;
    final inTransfers = ref
        .watch(transfersEpisodeIndexProvider)
        .statusOf(e.showName, e.seasonNumber, e.episodeNumber);
    if (inTransfers != EpisodeStatus.none) return inTransfers;

    final tracking = ref.watch(showAutoDownloadTrackingProvider(e.showId));
    if (tracking != null &&
        tracking.season == e.seasonNumber &&
        tracking.episode == e.episodeNumber) {
      switch (tracking.status) {
        case EpisodeDownloadStatus.downloading:
          return EpisodeStatus.downloading;
        case EpisodeDownloadStatus.downloaded:
        case EpisodeDownloadStatus.watched:
          return EpisodeStatus.downloaded;
        case EpisodeDownloadStatus.notAired:
        case EpisodeDownloadStatus.awaitingTorrent:
        case EpisodeDownloadStatus.available:
          break;
      }
    }

    final library = ref.watch(localMediaFilesProvider).value ?? const [];
    if (libraryHasEpisode(
      library,
      e.showName,
      e.seasonNumber,
      e.episodeNumber,
    )) {
      return EpisodeStatus.downloaded;
    }
    return EpisodeStatus.none;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = _status(ref);
    if (status == EpisodeStatus.downloaded ||
        status == EpisodeStatus.downloading) {
      return EditorialBadge(status.label, tone: status.color);
    }

    final unaired = episode.isUnairedOn(today);
    final label = busy ? 'Starting…' : 'Download';
    final enabled = !unaired && !busy;
    final fg = enabled ? AppColors.onAccent : AppColors.fg2;
    return HubPressable(
      onTap: enabled ? onDownload : null,
      tooltip: unaired ? "It hasn't aired yet" : null,
      semanticLabel: 'Download ${episode.showName} ${episode.episodeCode}',
      excludeChildSemantics: true,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: enabled ? AppColors.accent : AppColors.bgSurfaceHi,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: enabled ? AppColors.accent : AppColors.line,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: AppColors.fg2,
                ),
              )
            else
              Icon(Icons.download_rounded, size: 13, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppType.ui(
                size: AppType.sizeCaption,
                color: fg,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
