import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../models/episode.dart';
import '../models/season.dart';
import '../models/show.dart';
import '../providers/shows_provider.dart' show tmdbApiServiceProvider;
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
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
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.0,
      );
    }
  }

  /// Determine an episode's lifecycle state by joining torrent list
  /// + watch progress. Returns a single status — `watched` wins over
  /// `downloaded` wins over `downloading` wins over `none`.
  _EpisodeStatus _statusFor(Episode ep) {
    final code =
        'S${ep.seasonNumber.toString().padLeft(2, '0')}'
        'E${ep.episodeNumber.toString().padLeft(2, '0')}';
    final showName = widget.show.name.toLowerCase();

    final progress = ref.read(continueWatchingProvider);
    final hasWatched = progress.any(
      (p) =>
          p.isCompleted &&
          (p.episodeCode?.toLowerCase() == code.toLowerCase()) &&
          (p.showName?.toLowerCase().contains(showName) ?? false),
    );
    if (hasWatched) return _EpisodeStatus.watched;

    final torrents = ref.read(torrentListProvider).torrents;
    for (final t in torrents) {
      final n = t.name.toLowerCase();
      if (!n.contains(code.toLowerCase())) continue;
      // Match the show roughly: at least the first significant token.
      final showFirst = showName.split(' ').first;
      if (showFirst.length < 3 || n.contains(showFirst)) {
        if (t.isDownloading) return _EpisodeStatus.downloading;
        return _EpisodeStatus.downloaded;
      }
    }
    return _EpisodeStatus.none;
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
          _DrawerHeader(
            show: widget.show,
            onClose: () => Navigator.of(context).pop(),
          ),
          _SeasonTabs(
            seasonNumbers: seasonNumbers,
            selected: _season,
            onSelect: (n) {
              setState(() => _season = n);
              _loadSeason(n);
            },
          ),
          if (eps.isNotEmpty)
            _EpisodePicker(
              episodes: eps,
              onSelect: _scrollToEpisode,
              statusFor: _statusFor,
            ),
          Expanded(
            child: _loading && eps.isEmpty
                ? const _EpisodesSkeleton()
                : _error != null && eps.isEmpty
                ? _ErrorState(onRetry: () => _loadSeason(_season))
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
                      return _EpisodeRow(
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
    final code =
        'S${ep.seasonNumber.toString().padLeft(2, '0')}'
        'E${ep.episodeNumber.toString().padLeft(2, '0')}';
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

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({required this.show, required this.onClose});

  final Show show;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.seedColor, AppColors.accentTertiary],
              ),
              borderRadius: BorderRadius.circular(2),
              boxShadow: [
                BoxShadow(
                  color: AppColors.seedColor.withAlpha(120),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BROWSE EPISODES',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.seedColor,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.88,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  show.name,
                  style: const TextStyle(
                    fontSize: 22,
                    color: Color(0xFFF4F4F8),
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.44,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${show.numberOfSeasons ?? 0} '
                  '${(show.numberOfSeasons ?? 0) == 1 ? 'season' : 'seasons'}'
                  ' · ${show.numberOfEpisodes ?? 0} episodes',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF7A7A92),
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            tooltip: 'Close (Esc)',
            icon: const Icon(Icons.close_rounded, size: 16),
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xFF7A7A92),
              backgroundColor: AppColors.bgSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                side: const BorderSide(color: Color(0x0FFFFFFF)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonTabs extends StatelessWidget {
  const _SeasonTabs({
    required this.seasonNumbers,
    required this.selected,
    required this.onSelect,
  });

  final List<int> seasonNumbers;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      child: Row(
        children: [
          const Text(
            'SEASON',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFF7A7A92),
              letterSpacing: 0.88,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final n in seasonNumbers) ...[
                    _SeasonChip(
                      number: n,
                      selected: n == selected,
                      onTap: () => onSelect(n),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeasonChip extends StatelessWidget {
  const _SeasonChip({
    required this.number,
    required this.selected,
    required this.onTap,
  });

  final int number;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 28,
        decoration: BoxDecoration(
          color: selected ? AppColors.seedColor : AppColors.bgSurface,
          border: Border.all(
            color: selected ? AppColors.seedColor : const Color(0x0FFFFFFF),
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        alignment: Alignment.center,
        child: Text(
          number.toString().padLeft(2, '0'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            color: selected ? Colors.white : const Color(0xFFB4B4C8),
          ),
        ),
      ),
    );
  }
}

/// Per-episode lifecycle status. Reused by the picker pills + the
/// row to give a single visual language across the drawer.
enum _EpisodeStatus { none, downloading, downloaded, watched }

extension on _EpisodeStatus {
  Color get color => switch (this) {
    _EpisodeStatus.watched => AppColors.seeding,
    _EpisodeStatus.downloaded => AppColors.seedColor,
    _EpisodeStatus.downloading => AppColors.downloading,
    _EpisodeStatus.none => const Color(0xFF54546A),
  };

  IconData? get icon => switch (this) {
    _EpisodeStatus.watched => Icons.check_rounded,
    _EpisodeStatus.downloaded => Icons.download_done_rounded,
    _EpisodeStatus.downloading => Icons.downloading_rounded,
    _EpisodeStatus.none => null,
  };

  String get label => switch (this) {
    _EpisodeStatus.watched => 'Watched',
    _EpisodeStatus.downloaded => 'Downloaded',
    _EpisodeStatus.downloading => 'Downloading',
    _EpisodeStatus.none => '',
  };
}

/// Quick-jump pill row above the episode list — each pill is one
/// episode. Tapping scrolls the list to that episode. Watched
/// episodes are dimmed; downloaded episodes get a small dot.
class _EpisodePicker extends StatelessWidget {
  const _EpisodePicker({
    required this.episodes,
    required this.onSelect,
    required this.statusFor,
  });

  final List<Episode> episodes;
  final ValueChanged<int> onSelect;
  final _EpisodeStatus Function(Episode) statusFor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.md,
        AppSpacing.xl,
        AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1)),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: AppSpacing.sm, top: 6),
            child: Text(
              'EPISODE',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF7A7A92),
                letterSpacing: 0.88,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final ep in episodes) ...[
                    _EpisodePill(
                      episode: ep,
                      status: statusFor(ep),
                      onTap: () => onSelect(ep.episodeNumber),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EpisodePill extends StatelessWidget {
  const _EpisodePill({
    required this.episode,
    required this.status,
    required this.onTap,
  });

  final Episode episode;
  final _EpisodeStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isWatched = status == _EpisodeStatus.watched;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 28,
        decoration: BoxDecoration(
          color: AppColors.bgSurface,
          border: Border.all(
            color: status == _EpisodeStatus.none
                ? const Color(0x0FFFFFFF)
                : status.color.withAlpha(0x66),
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        alignment: Alignment.center,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Text(
              episode.episodeNumber.toString().padLeft(2, '0'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: isWatched
                    ? const Color(0xFF7A7A92)
                    : const Color(0xFFB4B4C8),
              ),
            ),
            if (status != _EpisodeStatus.none)
              Positioned(
                top: 2,
                right: 2,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: status.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeRow extends StatefulWidget {
  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.status,
    required this.onTap,
    this.watchedRatio,
  });

  final Episode episode;
  final _EpisodeStatus status;
  final VoidCallback onTap;

  /// 0.0–1.0 if the user has watched part/all of the episode. Renders a
  /// thin tertiary-colored progress bar at the bottom of the still.
  final double? watchedRatio;

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final hue = (ep.name.codeUnits.fold<int>(0, (a, b) => a + b)) % 360;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          // Subtle hover lift so the row feels tactile.
          scale: _hover ? 1.012 : 1.0,
          duration: AppDuration.fast,
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: AppDuration.fast,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: _hover ? AppColors.bgSurfaceHi : AppColors.bgSurface,
              border: Border.all(
                color: _hover
                    ? const Color(0x33FFFFFF)
                    : const Color(0x0FFFFFFF),
              ),
              borderRadius: BorderRadius.circular(AppRadius.md),
              boxShadow: _hover
                  ? const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 36,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        ep.episodeNumber.toString().padLeft(2, '0'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          // Watched episodes dim slightly so the user
                          // can scan unwatched ones at a glance.
                          color: widget.status == _EpisodeStatus.watched
                              ? const Color(0xFF7A7A92)
                              : const Color(0xFFF4F4F8),
                          letterSpacing: -0.36,
                          fontFamily: 'monospace',
                        ),
                      ),
                      if (widget.status.icon != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: widget.status.color.withAlpha(36),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              widget.status.icon,
                              size: 10,
                              color: widget.status.color,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    width: 100,
                    height: 60,
                    child: _EpisodeStill(
                      stillUrl: ep.stillUrl,
                      hue: hue,
                      watchedRatio: widget.watchedRatio,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ep.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFF4F4F8),
                        ),
                      ),
                      if (ep.overview != null && ep.overview!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          ep.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFB4B4C8),
                            height: 1.4,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            [
                              if (ep.airDate != null) ep.airDate!.toUpperCase(),
                              if (ep.runtime != null) '${ep.runtime}m',
                            ].join(' · '),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF7A7A92),
                              letterSpacing: 0.4,
                              fontFamily: 'monospace',
                            ),
                          ),
                          if (widget.status != _EpisodeStatus.none) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: widget.status.color.withAlpha(36),
                                borderRadius: BorderRadius.circular(
                                  AppRadius.xs,
                                ),
                              ),
                              child: Text(
                                widget.status.label.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  fontFamily: 'monospace',
                                  letterSpacing: 0.5,
                                  color: widget.status.color,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                _ActionButton(
                  status: widget.status,
                  hover: _hover,
                  onTap: widget.onTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Episode-row action button — switches label + icon + accent color
/// based on the lifecycle status. Replaces the always-`GET` button.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.status,
    required this.hover,
    required this.onTap,
  });

  final _EpisodeStatus status;
  final bool hover;
  final VoidCallback onTap;

  ({IconData icon, String label, Color color}) _spec() {
    return switch (status) {
      _EpisodeStatus.watched => (
        icon: Icons.replay_rounded,
        label: 'REWATCH',
        color: AppColors.seeding,
      ),
      _EpisodeStatus.downloaded => (
        icon: Icons.play_arrow_rounded,
        label: 'OPEN',
        color: AppColors.seeding,
      ),
      _EpisodeStatus.downloading => (
        icon: Icons.downloading_rounded,
        label: 'IN PROGRESS',
        color: AppColors.downloading,
      ),
      _EpisodeStatus.none => (
        icon: Icons.download_rounded,
        label: 'GET',
        color: AppColors.seedColor,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hover ? spec.color : spec.color.withAlpha(36),
          border: Border.all(color: spec.color.withAlpha(0x66)),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(spec.icon, size: 11, color: hover ? Colors.white : spec.color),
            const SizedBox(width: 4),
            Text(
              spec.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                fontFamily: 'monospace',
                color: hover ? Colors.white : spec.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFFB7185),
            size: 32,
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Failed to load episodes',
            style: TextStyle(color: Color(0xFFB4B4C8)),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// Pulsing skeleton rows shown while a season's episodes are being
/// fetched. Replaces the bare `CircularProgressIndicator` so the drawer
/// shows shape immediately and feels more responsive.
class _EpisodesSkeleton extends StatefulWidget {
  const _EpisodesSkeleton();

  @override
  State<_EpisodesSkeleton> createState() => _EpisodesSkeletonState();
}

class _EpisodesSkeletonState extends State<_EpisodesSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: 6,
      itemBuilder: (_, __) => AnimatedBuilder(
        animation: _controller,
        builder: (_, __) {
          // Sweeping alpha from subtle → light → subtle for a calm pulse.
          final t = Curves.easeInOut.transform(_controller.value);
          final alpha =
              (AppOpacity.subtle + (AppOpacity.light - AppOpacity.subtle) * t) /
              255.0;
          final base = Colors.white.withValues(alpha: alpha);
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.bgSurface,
              border: Border.all(color: const Color(0x0FFFFFFF)),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 22,
                  decoration: BoxDecoration(
                    color: base,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Container(
                  width: 100,
                  height: 60,
                  decoration: BoxDecoration(
                    color: base,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 160,
                        height: 12,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 220,
                        height: 9,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 100,
                        height: 9,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Episode still image with a deterministic gradient placeholder fallback
/// (driven by the episode title hash so each row is visually distinct
/// while loading or when TMDB has no still).
///
/// When [watchedRatio] is set, a thin tertiary-tinted progress bar runs
/// along the bottom of the still showing the user how far they got — a
/// glanceable "you watched this much" cue.
class _EpisodeStill extends StatelessWidget {
  const _EpisodeStill({
    required this.stillUrl,
    required this.hue,
    this.watchedRatio,
  });

  final String? stillUrl;
  final int hue;
  final double? watchedRatio;

  @override
  Widget build(BuildContext context) {
    final placeholder = _gradientPlaceholder();
    final url = stillUrl;
    final image = (url == null || url.isEmpty)
        ? placeholder
        : Image.network(
            url,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return placeholder;
            },
            errorBuilder: (_, __, ___) => placeholder,
          );

    final ratio = watchedRatio;
    if (ratio == null || ratio <= 0) return image;

    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        image,
        // Subtle dim on already-watched portion so unwatched stills pop.
        Container(
          color: Colors.black.withValues(alpha: AppOpacity.light / 255.0),
        ),
        // Progress bar pinned to the bottom edge.
        Align(
          alignment: Alignment.bottomLeft,
          child: FractionallySizedBox(
            widthFactor: ratio.clamp(0.0, 1.0),
            child: Container(height: 3, color: scheme.tertiary),
          ),
        ),
      ],
    );
  }

  Widget _gradientPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.32).toColor(),
            HSLColor.fromAHSL(1, (hue + 30) % 360, 0.5, 0.16).toColor(),
          ],
        ),
      ),
    );
  }
}
