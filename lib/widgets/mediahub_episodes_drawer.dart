import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../models/season.dart';
import '../models/show.dart';
import '../providers/shows_provider.dart' show tmdbApiServiceProvider;
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../utils/formatters.dart';
import 'common/mediahub_drawer_header.dart';
import 'episodes/episode_picker.dart';
import 'episodes/episode_row.dart';
import 'episodes/episode_states.dart';
import 'episodes/season_tabs.dart';
import 'mediahub_drawer.dart';

/// Right-side drawer presenting a show's seasons + episodes — replaces
/// the inline "Seasons & Episodes" section that previously occupied
/// the show details main page.
///
/// Layout:
///   * Header — "BROWSE EPISODES" kicker + show title + ✕ close
///   * Season tab strip (`01 02 03 …`)
///   * Scrollable episode list — each row shows episode #, name,
///     air date, runtime + a GET button that fires `onEpisodeTap`
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

  @override
  ConsumerState<MediaHubEpisodesDrawer> createState() =>
      _MediaHubEpisodesDrawerState();
}

class _MediaHubEpisodesDrawerState
    extends ConsumerState<MediaHubEpisodesDrawer> {
  late int _season = widget.initialSeason;
  final Map<int, List<Episode>> _episodes = {};
  final Map<int, GlobalKey> _episodeKeys = {};
  final ScrollController _listController = ScrollController();
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadSeason(_season);
  }

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  void _scrollToEpisode(int episodeNumber) {
    final key = _episodeKeys[episodeNumber];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: AppDuration.normal,
        curve: Curves.easeOutCubic,
        alignment: 0.0,
      );
    }
  }

  /// Determine an episode's lifecycle state by joining torrent list
  /// + watch progress. Returns a single status — `watched` wins over
  /// `downloaded` wins over `downloading` wins over `none`.
  EpisodeStatus _statusFor(Episode ep) {
    final code = Formatters.episodeCode(ep.seasonNumber, ep.episodeNumber);
    final showName = widget.show.name.toLowerCase();

    // `watchedIndexProvider` is the single source of truth — deliberately
    // not `continueWatchingProvider` (which strips out `isCompleted`
    // items) and not `watchedItemsProvider` (which requires the file to
    // still exist), because a watched mark has to survive deleting the
    // file and re-downloading it later.
    //
    // `watch`, not `read`: this used to read the map once, so marking an
    // episode watched while the drawer was open left the row stale until
    // it was rebuilt for some unrelated reason.
    final watched = ref.watch(watchedIndexProvider);
    if (watched.isEpisodeWatched(
      showId: widget.show.id,
      season: ep.seasonNumber,
      episode: ep.episodeNumber,
      showName: showName,
    )) {
      return EpisodeStatus.watched;
    }

    final torrents = ref.read(torrentListProvider).torrents;
    for (final t in torrents) {
      final n = t.name.toLowerCase();
      if (!n.contains(code.toLowerCase())) continue;
      // Match the show roughly: at least the first significant token.
      final showFirst = showName.split(' ').first;
      if (showFirst.length < 3 || n.contains(showFirst)) {
        if (t.isDownloading) return EpisodeStatus.downloading;
        return EpisodeStatus.downloaded;
      }
    }
    return EpisodeStatus.none;
  }

  Future<void> _loadSeason(int season) async {
    if (_episodes.containsKey(season)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = ref.read(tmdbApiServiceProvider);
      final eps = await svc.getSeasonEpisodes(widget.show.id, season);
      if (!mounted) return;
      setState(() {
        _episodes[season] = eps;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final eps = _episodes[_season] ?? const <Episode>[];
    // Filter out specials (season 0) — drawer focuses on aired
    // episodes the user actually wants to grab.
    final seasonNumbers = widget.seasons
        .where((s) => s.seasonNumber > 0)
        .map((s) => s.seasonNumber)
        .toList();

    return Padding(
      padding: const EdgeInsets.only(left: MediaHubDrawer.dragGripWidth),
      child: Column(
        children: [
          MediaHubDrawerHeader(
            kicker: 'BROWSE EPISODES',
            title: widget.show.name,
            subtitle:
                '${widget.show.numberOfSeasons ?? 0} '
                '${(widget.show.numberOfSeasons ?? 0) == 1 ? 'SEASON' : 'SEASONS'}'
                ' · ${widget.show.numberOfEpisodes ?? 0} EPISODES',
            subtitleUppercase: true,
            onClose: () => Navigator.of(context).pop(),
          ),
          SeasonTabs(
            seasonNumbers: seasonNumbers,
            selected: _season,
            onSelect: (n) {
              setState(() => _season = n);
              _loadSeason(n);
            },
          ),
          if (eps.isNotEmpty)
            EpisodePicker(
              episodes: eps,
              onSelect: _scrollToEpisode,
              statusFor: _statusFor,
            ),
          Expanded(
            child: _loading && eps.isEmpty
                ? const EpisodesSkeleton()
                : _error != null && eps.isEmpty
                ? EpisodesErrorState(onRetry: () => _loadSeason(_season))
                : ListView.builder(
                    controller: _listController,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: eps.length,
                    itemBuilder: (_, i) {
                      final ep = eps[i];
                      final key = _episodeKeys.putIfAbsent(
                        ep.episodeNumber,
                        () => GlobalKey(),
                      );
                      return EpisodeRow(
                        key: key,
                        episode: ep,
                        status: _statusFor(ep),
                        onTap: () => widget.onEpisodeTap(ep),
                        watchedRatio: _watchedRatioFor(ep),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// Returns 0.0–1.0 of how much of the episode the user has watched, or
  /// `null` when nothing is recorded. Drives the watched-progress overlay
  /// at the bottom of each episode still.
  double? _watchedRatioFor(Episode ep) {
    final code = Formatters.episodeCode(ep.seasonNumber, ep.episodeNumber);
    final showName = widget.show.name.toLowerCase();
    final progress = ref.read(continueWatchingProvider);
    for (final p in progress) {
      if (p.episodeCode?.toLowerCase() != code.toLowerCase()) continue;
      if (!(p.showName?.toLowerCase().contains(showName) ?? false)) continue;
      final dur = p.duration.inMilliseconds;
      if (dur <= 0) return null;
      return (p.position.inMilliseconds / dur).clamp(0.0, 1.0);
    }
    return null;
  }
}
