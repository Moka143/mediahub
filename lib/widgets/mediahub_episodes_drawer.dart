import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../models/local_media_file.dart';
import '../models/season.dart';
import '../models/show.dart';
import '../models/watched_index.dart';
import '../providers/local_media_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../utils/error_messages.dart';
import '../utils/media_names.dart';
import 'common/mediahub_drawer_header.dart';
import 'episodes/episode_picker.dart';
import 'episodes/episode_row.dart';
import 'episodes/episode_states.dart';
import 'episodes/episode_status.dart';
import 'episodes/season_tabs.dart';
import 'mediahub_drawer.dart';

/// Right-side drawer presenting a show's seasons + episodes.
///
/// Layout:
///   * Header — "BROWSE EPISODES" kicker + show title + ✕ close
///   * Season strip (`01 02 03 …`)
///   * Episode quick-jump strip
///   * Episode list — each row opens the episode through [onEpisodeTap]
class MediaHubEpisodesDrawer extends ConsumerStatefulWidget {
  const MediaHubEpisodesDrawer({
    super.key,
    required this.show,
    required this.seasons,
    required this.initialSeason,
    required this.onEpisodeTap,
  });

  final Show show;
  final List<Season> seasons;
  final int initialSeason;
  final void Function(Episode episode) onEpisodeTap;

  /// Slide-in helper — same shape as `MediaHubTorrentDrawer.show`.
  /// Backdrop blur, tap-out, drag-to-dismiss, and slide animation are
  /// all handled by [MediaHubDrawer].
  static Future<void> open({
    required BuildContext context,
    required Show show,
    required List<Season> seasons,
    int initialSeason = 1,
    required void Function(Episode episode) onEpisodeTap,
  }) {
    return MediaHubDrawer.show<void>(
      context: context,
      builder: (_) => MediaHubEpisodesDrawer(
        show: show,
        seasons: seasons,
        initialSeason: initialSeason,
        onEpisodeTap: onEpisodeTap,
      ),
    );
  }

  /// The seasons to offer as tabs: specials (season 0) are left out — the
  /// drawer is for episodes people want to watch — unless a show has
  /// nothing else, which used to open on a season no tab was selected for.
  static List<int> tabSeasons(List<Season> seasons) {
    final regular = [
      for (final s in seasons)
        if (s.seasonNumber > 0) s.seasonNumber,
    ];
    if (regular.isNotEmpty) return regular;
    return [for (final s in seasons) s.seasonNumber];
  }

  @override
  ConsumerState<MediaHubEpisodesDrawer> createState() =>
      _MediaHubEpisodesDrawerState();
}

class _MediaHubEpisodesDrawerState
    extends ConsumerState<MediaHubEpisodesDrawer> {
  final ScrollController _listController = ScrollController();
  late final List<int> _seasonNumbers = MediaHubEpisodesDrawer.tabSeasons(
    widget.seasons,
  );
  late int _season = _seasonNumbers.contains(widget.initialSeason)
      ? widget.initialSeason
      : (_seasonNumbers.isEmpty ? widget.initialSeason : _seasonNumbers.first);

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  ({int showId, int seasonNumber}) get _seasonKey =>
      (showId: widget.show.id, seasonNumber: _season);

  void _selectSeason(int season) {
    if (season == _season) return;
    setState(() => _season = season);
    if (_listController.hasClients) _listController.jumpTo(0);
  }

  /// Scroll episode [index] to the top of the list.
  ///
  /// By arithmetic over the fixed row height, through the list's own
  /// controller. It used to look the row up by a GlobalKey, which only
  /// exists once the row is built — and a lazy list builds only the ten or
  /// so rows on screen, so jumping to episode 15 of 22 did nothing at all.
  void _scrollToIndex(int index, double extent) {
    if (!_listController.hasClients) return;
    final max = _listController.position.maxScrollExtent;
    unawaited(
      _listController.animateTo(
        (index * extent).clamp(0.0, max),
        duration: AppDuration.normal,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// One status per episode — watched wins over Transfers, which wins over
  /// a file in the library.
  ///
  /// Every source is watched, not read once: marking an episode watched, or
  /// a download started from this very drawer, shows on its row at once —
  /// the row used to keep saying "Stream", inviting a duplicate download.
  EpisodeStatus _statusFor(
    Episode ep, {
    required WatchedIndex watched,
    required TransfersEpisodeIndex transfers,
    required List<LocalMediaFile> library,
  }) {
    final show = widget.show;
    if (watched.isEpisodeWatched(
      showId: show.id,
      season: ep.seasonNumber,
      episode: ep.episodeNumber,
      showName: show.name,
    )) {
      return EpisodeStatus.watched;
    }
    final inTransfers = transfers.statusOf(
      show.name,
      ep.seasonNumber,
      ep.episodeNumber,
    );
    if (inTransfers != EpisodeStatus.none) return inTransfers;
    if (libraryHasEpisode(
      library,
      show.name,
      ep.seasonNumber,
      ep.episodeNumber,
    )) {
      return EpisodeStatus.downloaded;
    }
    return EpisodeStatus.none;
  }

  @override
  Widget build(BuildContext context) {
    final show = widget.show;
    final seasonCount = show.numberOfSeasons ?? _seasonNumbers.length;
    final episodeCount = show.numberOfEpisodes;
    final extent = EpisodeRow.extentFor(MediaQuery.textScalerOf(context));

    final episodesAsync = ref.watch(seasonEpisodesProvider(_seasonKey));
    final watched = ref.watch(watchedIndexProvider);
    final transfers = ref.watch(transfersEpisodeIndexProvider);
    final library = ref.watch(localMediaFilesProvider).value ?? const [];
    final inProgress = ref.watch(continueWatchingProvider);

    EpisodeStatus statusFor(Episode ep) => _statusFor(
      ep,
      watched: watched,
      transfers: transfers,
      library: library,
    );

    double? watchedRatioFor(Episode ep) {
      for (final p in inProgress) {
        if (p.seasonNumber != ep.seasonNumber ||
            p.episodeNumber != ep.episodeNumber) {
          continue;
        }
        final sameShow =
            p.showId == show.id ||
            (p.showName != null && titlesMatch(p.showName!, show.name));
        if (!sameShow) continue;
        return p.progress;
      }
      return null;
    }

    // Data first, then error, then loading: while Riverpod retries a failed
    // request in the background the value is "loading" with an error
    // attached, and showing the skeleton for the ~40 s of retries left the
    // drawer blank when offline.
    final List<Episode>? episodes = episodesAsync.value;
    final Widget body;
    if (episodes != null) {
      body = episodes.isEmpty
          ? const EpisodesEmptyState()
          : ListView.builder(
              controller: _listController,
              padding: const EdgeInsets.all(AppSpacing.md),
              itemExtent: extent,
              itemCount: episodes.length,
              itemBuilder: (_, i) {
                final ep = episodes[i];
                return EpisodeRow(
                  episode: ep,
                  status: statusFor(ep),
                  onTap: () => widget.onEpisodeTap(ep),
                  watchedRatio: watchedRatioFor(ep),
                );
              },
            );
    } else if (episodesAsync.hasError) {
      body = EpisodesErrorState(
        message: friendlyErrorMessage(
          episodesAsync.error!,
          subject: 'this season',
        ),
        onRetry: () => ref.invalidate(seasonEpisodesProvider(_seasonKey)),
      );
    } else {
      body = const EpisodesSkeleton();
    }

    return Padding(
      padding: const EdgeInsets.only(left: MediaHubDrawer.dragGripWidth),
      child: Column(
        children: [
          MediaHubDrawerHeader(
            kicker: 'BROWSE EPISODES',
            title: show.name,
            subtitle: [
              seasonCount == 1 ? '1 season' : '$seasonCount seasons',
              if (episodeCount != null)
                episodeCount == 1 ? '1 episode' : '$episodeCount episodes',
            ].join(' · '),
            subtitleUppercase: true,
            onClose: () => Navigator.of(context).pop(),
          ),
          if (_seasonNumbers.isNotEmpty)
            SeasonTabs(
              seasonNumbers: _seasonNumbers,
              selected: _season,
              onSelect: _selectSeason,
            ),
          if (episodes != null && episodes.isNotEmpty)
            EpisodePicker(
              episodes: episodes,
              onSelect: (index) => _scrollToIndex(index, extent),
              statusFor: statusFor,
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
