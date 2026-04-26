import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_theme.dart';
import '../design/app_tokens.dart';
import '../models/local_media_file.dart';
import '../models/show.dart';
import '../models/torrent.dart';
import '../models/watch_progress.dart';
import '../providers/local_media_provider.dart';
import '../providers/movies_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/shows_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../screens/movie_details_screen.dart';
import '../screens/show_details_screen.dart';
import '../screens/video_player_screen.dart';
import '../utils/formatters.dart';
import '../widgets/common/status_badge.dart';

/// Build a TMDB image URL from a poster path (e.g. `/abc.jpg`).
/// Returns null if the path is null or empty. If the input already
/// looks like an absolute URL, return it untouched so callers don't
/// double-prefix when the path was previously resolved.
String? _tmdbPoster(String? p, {String size = 'w500'}) {
  if (p == null || p.isEmpty) return null;
  if (p.startsWith('http://') || p.startsWith('https://')) return p;
  final prefix = p.startsWith('/') ? '' : '/';
  return 'https://image.tmdb.org/t/p/$size$prefix$p';
}

/// Strip episode/year/quality tail from a torrent or filename so the
/// remainder is usable as a TMDB search query. Returns the cleaned
/// title (spaces, no separators), or an empty string when nothing
/// recognizable remains.
String _searchTitleFromTorrentName(String name) {
  String n = name;
  // Drop file extension when it looks like one (≤5 chars after the dot).
  final lastDot = n.lastIndexOf('.');
  if (lastDot > 0 && n.length - lastDot <= 5) {
    n = n.substring(0, lastDot);
  }
  // Cut at the first season/episode/year/quality marker — everything
  // before it is the title; everything after is release metadata.
  final stop = RegExp(
    r'[\s._\-]+(?:[Ss]\d{1,2}[Ee]\d{1,2}|\d{1,2}x\d{1,2}|(?:19|20)\d{2}|2160p|1080p|720p|480p|UHD|4K|HDTV|WEB[-.]?DL|WEBRip|BluRay|BDRip|HDR|x264|x265|HEVC)',
    caseSensitive: false,
  );
  final m = stop.firstMatch(n);
  if (m != null) n = n.substring(0, m.start);
  return n
      .replaceAll('.', ' ')
      .replaceAll('_', ' ')
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Open the video player for a Continue-Watching entry, seeking to
/// the saved position. Falls back to a synthetic LocalMediaFile when
/// the file isn't yet in the scanned library (e.g. a torrent that
/// completed but the scanner hasn't picked it up).
void _resumePlayback(
  BuildContext context,
  WidgetRef ref,
  WatchProgress progress,
  List<LocalMediaFile> localFiles,
) {
  final file = localFiles.firstWhere(
    (f) => f.path == progress.filePath,
    orElse: () {
      final name = progress.filePath.split('/').last.split('\\').last;
      final ext = name.contains('.') ? name.split('.').last : '';
      return LocalMediaFile(
        path: progress.filePath,
        fileName: name,
        sizeBytes: 0,
        modifiedDate: DateTime.now(),
        extension: ext,
        showName: progress.showName,
        seasonNumber: progress.seasonNumber,
        episodeNumber: progress.episodeNumber,
        progress: progress,
      );
    },
  );
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => VideoPlayerScreen(
        file: file,
        startPosition: progress.position,
      ),
    ),
  );
}

/// Procedural fallback when no real artwork is available — keeps the
/// dark cinematic feel even before TMDB poster paths come back.
Widget _hueBackdrop(int hue) {
  return DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.22).toColor(),
          HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.08).toColor(),
        ],
      ),
    ),
  );
}

/// MediaHub Home — landing page that mirrors `screen-home.jsx`.
///
/// Layout:
///   * Hero card showcasing the most-recent in-progress title (with a
///     Resume CTA when a `WatchProgress` is available, otherwise a
///     poetic empty state for first-run).
///   * Continue Watching row — 16:9 cards with progress bars.
///   * Freshly Downloaded row — recently-completed torrents.
///   * Two side-by-side panels: Active Downloads (live dl speeds)
///     and "Airing tonight" placeholder.
class MediaHubHomeScreen extends ConsumerWidget {
  const MediaHubHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final continueWatching = ref.watch(continueWatchingProvider);
    final torrents = ref.watch(torrentListProvider).torrents;
    final activeDl = torrents.where((t) => t.isDownloading).toList();
    final freshlyCompleted = torrents
        .where((t) => t.isCompleted || t.isSeeding)
        .toList()
        .reversed
        .take(8)
        .toList();

    // Build a poster lookup table by joining the user's watch
    // progress + local media library — so torrent rows that match a
    // tracked title can render the real TMDB art instead of a flat
    // gradient.
    final progressMap = ref.watch(watchProgressProvider);
    final localFilesAsync = ref.watch(localMediaFilesProvider);
    final localFiles = localFilesAsync.maybeWhen(
      data: (f) => f,
      orElse: () => const <LocalMediaFile>[],
    );
    String? lookupPosterForTorrent(Torrent t) {
      final lower = t.name.toLowerCase();
      // 1) Exact-ish hash match against active streaming entries.
      for (final p in progressMap.values) {
        if (p.posterPath == null || p.posterPath!.isEmpty) continue;
        final showName = p.showName?.toLowerCase();
        if (showName != null && showName.length > 2 &&
            lower.contains(showName)) {
          return p.posterPath;
        }
      }
      // 2) Fall back to the local-media scanner — it tags scanned
      //    files with the resolved show name + poster path.
      for (final f in localFiles) {
        if (f.posterPath == null || f.posterPath!.isEmpty) continue;
        final s = f.showName?.toLowerCase();
        if (s != null && s.length > 2 && lower.contains(s)) {
          return f.posterPath;
        }
      }
      return null;
    }

    // TMDB trending feeds — used to populate the hero + a "Trending"
    // row when the user has no watch progress yet, so the home page
    // always shows real poster art instead of empty gradients.
    final trendingShows = ref.watch(trendingShowsProvider);
    final trendingMovies = ref.watch(trendingMoviesProvider);

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HeroCard(
              continueWatching: continueWatching,
              fallbackShow: trendingShows.maybeWhen(
                data: (s) => s.isEmpty ? null : s.first,
                orElse: () => null,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),

            if (continueWatching.isNotEmpty) ...[
              _SectionHeader(
                title: 'Continue Watching',
                icon: Icons.play_arrow_rounded,
                accent: AppColors.seedColor,
                // Library tab is index 4 (Home, Transfers, TV Shows,
                // Movies, Library, Calendar, Favorites).
                onSeeAll: () =>
                    ref.read(currentTabIndexProvider.notifier).set(4),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 220,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  itemCount: continueWatching.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.md),
                  itemBuilder: (_, i) {
                    final p = continueWatching[i];
                    // If the WatchProgress entry has no poster path,
                    // try to find one by joining show name against
                    // the local-media library / other progress.
                    String? fallback;
                    if (p.posterPath == null || p.posterPath!.isEmpty) {
                      final name = p.showName?.toLowerCase() ?? '';
                      if (name.isNotEmpty) {
                        for (final f in localFiles) {
                          if (f.posterPath != null &&
                              (f.showName?.toLowerCase() == name)) {
                            fallback = f.posterPath;
                            break;
                          }
                        }
                      }
                    }
                    return _ContinueCard(
                      p: p,
                      posterFallback: fallback,
                      onTap: () => _resumePlayback(context, ref, p, localFiles),
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],

            // Trending Shows row — gives the page real poster art even
            // before the user has any continue-watching history.
            trendingShows.maybeWhen(
              data: (shows) => shows.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionHeader(
                          title: 'Trending shows',
                          icon: Icons.local_fire_department_rounded,
                          accent: AppColors.accentTertiary,
                          // Jump to the TV Shows tab.
                          onSeeAll: () => ref
                              .read(currentTabIndexProvider.notifier)
                              .set(2),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SizedBox(
                          height: 280,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            itemCount: shows.length.clamp(0, 14),
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: AppSpacing.md),
                            itemBuilder: (_, i) => _PosterTile(
                              imageUrl: shows[i].posterUrl,
                              hue: (shows[i].id * 37 % 360).toDouble(),
                              title: shows[i].name,
                              subtitle: shows[i].year,
                              quality: '4K',
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ShowDetailsScreen(show: shows[i]),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xxl),
                      ],
                    ),
              orElse: () => const SizedBox.shrink(),
            ),

            // Trending Movies row — same idea for movies.
            trendingMovies.maybeWhen(
              data: (movies) => movies.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionHeader(
                          title: 'Trending movies',
                          icon: Icons.movie_rounded,
                          accent: AppColors.accentPrimary,
                          // Jump to the Movies tab.
                          onSeeAll: () => ref
                              .read(currentTabIndexProvider.notifier)
                              .set(3),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        SizedBox(
                          height: 280,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            itemCount: movies.length.clamp(0, 14),
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: AppSpacing.md),
                            itemBuilder: (_, i) => _PosterTile(
                              imageUrl: movies[i].posterUrl,
                              hue: (movies[i].id * 53 % 360).toDouble(),
                              title: movies[i].title,
                              subtitle: movies[i].year,
                              quality: '4K',
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      MovieDetailsScreen(movie: movies[i]),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xxl),
                      ],
                    ),
              orElse: () => const SizedBox.shrink(),
            ),

            if (freshlyCompleted.isNotEmpty) ...[
              _SectionHeader(
                title: 'Freshly downloaded',
                icon: Icons.auto_awesome_rounded,
                accent: AppColors.seeding,
                // Jump to the Transfers tab.
                onSeeAll: () =>
                    ref.read(currentTabIndexProvider.notifier).set(1),
              ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 280,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  itemCount: freshlyCompleted.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.md),
                  itemBuilder: (_, i) => _FreshTile(
                    t: freshlyCompleted[i],
                    posterPath: lookupPosterForTorrent(freshlyCompleted[i]),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
            ],

            // Bottom panel row
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _MiniPanel(
                    title: 'Active downloads',
                    icon: Icons.download_rounded,
                    accent: AppColors.downloading,
                    count: activeDl.length,
                    child: activeDl.isEmpty
                        ? const _PanelEmpty(label: 'Nothing downloading')
                        : Column(
                            children: [
                              for (final t in activeDl.take(3))
                                _MiniTorrentRow(t: t),
                            ],
                          ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: _MiniPanel(
                    title: 'Airing tonight',
                    icon: Icons.local_fire_department_rounded,
                    accent: AppColors.accentTertiary,
                    count: 0,
                    child: const _PanelEmpty(
                      label: 'Auto-grab is quiet right now',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.continueWatching,
    this.fallbackShow,
  });

  final List<WatchProgress> continueWatching;
  /// When the user has no continue-watching items yet, the hero
  /// pulls art + title from this trending show so the page never
  /// shows an empty gradient on first run.
  final Show? fallbackShow;

  @override
  Widget build(BuildContext context) {
    final hero = continueWatching.isNotEmpty ? continueWatching.first : null;
    final fb = fallbackShow;
    final hue = hero != null
        ? (hero.showName?.codeUnits.fold<int>(0, (a, b) => a + b) ?? 220) % 360
        : (fb != null ? (fb.id * 37) % 360 : 220);

    final backdropUrl = _tmdbPoster(
          hero?.posterPath,
          size: 'original',
        ) ??
        // Fallback: backdrop from the trending show, if any.
        fb?.backdropUrl ??
        fb?.posterUrl;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: SizedBox(
        height: 360,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Real TMDB poster as the hero backdrop when we have one;
            // gradient fallback otherwise.
            if (backdropUrl != null)
              CachedNetworkImage(
                imageUrl: backdropUrl,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _hueBackdrop(hue),
                placeholder: (_, _) => _hueBackdrop(hue),
              )
            else
              _hueBackdrop(hue),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.6, -0.4),
                  radius: 1.0,
                  colors: [
                    HSLColor.fromAHSL(0.5, hue.toDouble(), 0.7, 0.3).toColor(),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  stops: const [0.0, 0.6, 1.0],
                  colors: [
                    AppColors.bgPage.withAlpha(178),
                    AppColors.bgPage.withAlpha(76),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.huge),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      StatusBadge(
                        label: hero != null
                            ? 'Continue Watching'
                            : (fb != null ? '▲ Trending' : 'Welcome'),
                        textColor: hero != null
                            ? AppColors.seedColor
                            : AppColors.accentTertiary,
                        size: StatusBadgeSize.small,
                      ),
                      if (hero?.episodeCode != null)
                        StatusBadge(
                          label: hero!.episodeCode!,
                          textColor: const Color(0xFFB4B4C8),
                          size: StatusBadgeSize.small,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    hero?.showName ??
                        hero?.episodeTitle ??
                        fb?.name ??
                        'MediaHub',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.3,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 540),
                    child: Text(
                      hero != null
                          ? 'Pick up where you left off — '
                                '${_progressLabel(hero)} remaining.'
                          : (fb?.overview != null && fb!.overview!.isNotEmpty
                              ? fb.overview!
                              : 'Browse Shows or Movies, queue a torrent, '
                                  'and start watching the moment it\'s ready.'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB4B4C8),
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                  ),
                  if (hero != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    SizedBox(
                      width: 320,
                      child: _ProgressBar(
                        progress: hero.position.inSeconds /
                            (hero.duration.inSeconds == 0
                                ? 1
                                : hero.duration.inSeconds),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(
                        onPressed: () {},
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(hero != null ? 'Resume' : 'Browse'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl,
                            vertical: AppSpacing.md,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      OutlinedButton(
                        onPressed: () {},
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0x33FFFFFF)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.xl,
                            vertical: AppSpacing.md,
                          ),
                        ),
                        child: const Text('More info'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _progressLabel(WatchProgress p) {
    final remaining = p.duration - p.position;
    final m = remaining.inMinutes;
    if (m < 1) return '< 1 min';
    if (m < 60) return '$m min';
    return '${m ~/ 60}h ${m % 60}m';
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: Stack(
          children: [
            Container(color: Colors.white.withAlpha(38)),
            FractionallySizedBox(
              widthFactor: progress.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.seedColor,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.seedColor.withAlpha(120),
                      blurRadius: 8,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.icon,
    required this.accent,
    this.onSeeAll,
  });

  final String title;
  final IconData icon;
  final Color accent;
  /// Tap handler for the "See all" button — when null, the button is
  /// hidden so we don't render a no-op control.
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: accent.withAlpha(36),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, size: 14, color: accent),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xFFF4F4F8),
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.18,
          ),
        ),
        const Spacer(),
        if (onSeeAll != null)
          TextButton.icon(
            onPressed: onSeeAll,
            icon: const Text(
              'See all',
              style: TextStyle(color: Color(0xFFB4B4C8), fontSize: 12),
            ),
            label: const Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: Color(0xFFB4B4C8),
            ),
          ),
      ],
    );
  }
}

class _ContinueCard extends ConsumerWidget {
  const _ContinueCard({required this.p, this.posterFallback, this.onTap});

  final WatchProgress p;
  /// Optional poster path used when `p.posterPath` is missing.
  final String? posterFallback;
  /// Tapping anywhere on the card resumes playback at the saved
  /// position. Wired up by the home screen.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hue =
        (p.showName?.codeUnits.fold<int>(0, (a, b) => a + b) ?? 220) % 360;
    final progressFraction = p.duration.inSeconds == 0
        ? 0.0
        : p.position.inSeconds / p.duration.inSeconds;
    // Pick the best poster path we have: native first, then fallback.
    final posterPath = (p.posterPath != null && p.posterPath!.isNotEmpty)
        ? p.posterPath
        : posterFallback;
    String? url = _tmdbPoster(posterPath, size: 'w780');

    // Last-resort TMDB lookup keyed on the show name (or filename) —
    // older watch-progress entries were created before posters were
    // captured, so we resolve them on demand here.
    if (url == null) {
      final fileName =
          p.filePath.split('/').last.split('\\').last;
      final query = (p.showName != null && p.showName!.isNotEmpty)
          ? p.showName!
          : _searchTitleFromTorrentName(fileName);
      if (query.isNotEmpty) {
        final isShow = p.episodeCode != null;
        final asyncPoster = isShow
            ? ref.watch(showPosterProvider(query))
            : ref.watch(moviePosterProvider(query));
        url = asyncPoster.maybeWhen(
          data: (u) => (u != null && u.isNotEmpty) ? u : null,
          orElse: () => null,
        );
      }
    }
    return SizedBox(
      width: 280,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: SizedBox(
                  width: 280,
                  height: 158,
                  child: url != null
                      ? CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) => _hueBackdrop(hue),
                          placeholder: (_, _) => _hueBackdrop(hue),
                        )
                      : _hueBackdrop(hue),
                ),
              ),
              // Subtle bottom darkening so the title overlay reads.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 80,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(AppRadius.md),
                    bottomRight: Radius.circular(AppRadius.md),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withAlpha(160),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Resume play badge — solid white pill so it reads as
              // an actionable control, not a faint overlay.
              Positioned(
                top: AppSpacing.sm,
                right: AppSpacing.sm,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(80),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    size: 22,
                    color: Colors.black,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: 3,
                  child: Stack(
                    children: [
                      Container(color: Colors.white.withAlpha(38)),
                      FractionallySizedBox(
                        widthFactor: progressFraction.clamp(0.0, 1.0),
                        child: Container(color: AppColors.seedColor),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            p.showName ?? p.episodeTitle ?? 'Untitled',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFF4F4F8),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (p.episodeCode != null) p.episodeCode!,
              if (p.episodeTitle != null) p.episodeTitle!,
            ].join(' — '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF7A7A92),
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 180×220 poster tile used in the Home "Trending" rows. Displays a
/// real TMDB poster when `imageUrl` is provided, falling back to a
/// hue gradient. Tapping opens the matching detail screen via
/// the supplied `onTap`.
class _PosterTile extends StatefulWidget {
  const _PosterTile({
    required this.imageUrl,
    required this.hue,
    required this.title,
    required this.subtitle,
    required this.quality,
    required this.onTap,
  });

  final String? imageUrl;
  final double hue;
  final String title;
  final String? subtitle;
  final String quality;
  final VoidCallback onTap;

  @override
  State<_PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<_PosterTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          transform: Matrix4.identity()
            ..translate(0.0, _hover ? -4.0 : 0.0),
          width: 180,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: SizedBox(
                  width: 180,
                  height: 220,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: widget.imageUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              _hueBackdrop(widget.hue.toInt()),
                          placeholder: (_, _) =>
                              _hueBackdrop(widget.hue.toInt()),
                        )
                      else
                        _hueBackdrop(widget.hue.toInt()),
                      Positioned(
                        top: AppSpacing.sm,
                        right: AppSpacing.sm,
                        child: StatusBadge.quality(
                          quality: widget.quality,
                          size: StatusBadgeSize.small,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFF4F4F8),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    widget.subtitle!,
                    style: const TextStyle(
                      color: Color(0xFF7A7A92),
                      fontSize: 10,
                      fontFamily: 'monospace',
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FreshTile extends ConsumerWidget {
  const _FreshTile({required this.t, this.posterPath});

  final Torrent t;
  /// Resolved TMDB poster path (e.g. `/abc.jpg`) — comes from joining
  /// the torrent name against watch progress + local media library.
  /// Falls back to a hue gradient when null.
  final String? posterPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hue =
        t.name.codeUnits.fold<int>(0, (a, b) => a + b) % 360;
    final quality = _qualityFromName(t.name);
    String? url = _tmdbPoster(posterPath, size: 'w500');

    // No poster from local progress / library — fall back to a live
    // TMDB lookup against the cleaned torrent name. Show vs. movie
    // is decided by whether the name contains a season/episode tag.
    if (url == null) {
      final isShow = RegExp(
        r'[Ss]\d{1,2}[Ee]\d{1,2}|\d{1,2}x\d{1,2}',
      ).hasMatch(t.name);
      final query = _searchTitleFromTorrentName(t.name);
      if (query.isNotEmpty) {
        final asyncPoster = isShow
            ? ref.watch(showPosterProvider(query))
            : ref.watch(moviePosterProvider(query));
        url = asyncPoster.maybeWhen(
          data: (u) => (u != null && u.isNotEmpty) ? u : null,
          orElse: () => null,
        );
      }
    }
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: SizedBox(
              width: 180,
              height: 220,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (url != null)
                    CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _hueBackdrop(hue),
                      placeholder: (_, _) => _hueBackdrop(hue),
                    )
                  else
                    _hueBackdrop(hue),
                  Positioned(
                    top: AppSpacing.sm,
                    right: AppSpacing.sm,
                    child: StatusBadge.quality(
                      quality: quality,
                      size: StatusBadgeSize.small,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _shortName(t.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFB4B4C8),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'NEW · ${quality.toUpperCase()}',
            style: const TextStyle(
              color: Color(0xFF7A7A92),
              fontSize: 10,
              letterSpacing: 0.4,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

String _shortName(String n) {
  final cleaned = n.split(RegExp(r'[\.\s]')).take(4).join(' ');
  return cleaned.isEmpty ? n : cleaned;
}

String _qualityFromName(String name) {
  final l = name.toLowerCase();
  if (l.contains('2160') || l.contains('uhd') || l.contains('4k')) return '4K';
  if (l.contains('1080')) return '1080p';
  if (l.contains('720')) return '720p';
  return 'SD';
}

class _MiniPanel extends StatelessWidget {
  const _MiniPanel({
    required this.title,
    required this.icon,
    required this.accent,
    required this.count,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Color accent;
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: const Color(0x0FFFFFFF)),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: accent.withAlpha(36),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(icon, size: 14, color: accent),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFFF4F4F8),
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (count > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withAlpha(36),
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: accent,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Text(
        label,
        style: const TextStyle(color: Color(0xFF7A7A92), fontSize: 12),
      ),
    );
  }
}

class _MiniTorrentRow extends StatelessWidget {
  const _MiniTorrentRow({required this.t});

  final Torrent t;

  @override
  Widget build(BuildContext context) {
    final ac = context.appColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFFF4F4F8),
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 3,
                    child: Stack(
                      children: [
                        Container(color: AppColors.bgSurfaceHi),
                        FractionallySizedBox(
                          widthFactor: t.progress.clamp(0.0, 1.0),
                          child: Container(color: AppColors.seedColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${(t.progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppColors.seedColor,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '↓ ${Formatters.formatSpeed(t.dlspeed)}',
                style: TextStyle(
                  fontSize: 10,
                  color: ac.downloading,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
