import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../design/app_tokens.dart';
import '../providers/auto_download_provider.dart';
import '../providers/connection_provider.dart' as connection_provider;
import '../providers/favorites_provider.dart';
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/tmdb_account_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/watch_progress_provider.dart';
import '../providers/watchlist_provider.dart';
import '../services/library_actions.dart';
import '../services/streaming_service.dart';
import '../utils/feedback_utils.dart';
import '../widgets/add_torrent_dialog.dart';
import '../widgets/common/mediahub_sidebar.dart';
import '../widgets/common/mediahub_topbar.dart';
import '../widgets/common/nav_badge.dart';
import '../widgets/connection_status_widget.dart';
import 'calendar_screen.dart';
import 'downloads_screen.dart';
import 'favorites_screen.dart';
import 'mediahub_home_screen.dart';
import 'movies_screen.dart';
import 'settings_screen.dart';
import 'shows_screen.dart';
import 'video_player_screen.dart';
import 'watch_screen.dart';

/// Main navigation screen with bottom navigation bar
class MainNavigationScreen extends ConsumerStatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  ConsumerState<MainNavigationScreen> createState() =>
      _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> {
  // Keep screens alive when switching tabs.
  // Index 0 is the new MediaHub Home (matches the design's primary
  // landing page); the existing tabs shift right by one.
  final List<Widget> _screens = const [
    MediaHubHomeScreen(),
    DownloadsScreen(),
    ShowsScreen(),
    MoviesScreen(),
    WatchScreen(),
    CalendarScreen(),
    FavoritesScreen(),
  ];

  /// Sidebar collapse state — auto-managed (expanded on wide displays
  /// by default, but the user can toggle).
  bool _sidebarCollapsed = false;

  @override
  void initState() {
    super.initState();
    // Pull authoritative favorites/watchlist from TMDB on launch when
    // already signed in. Best-effort: failures stay silent and the user
    // still sees the local cache. Also reconcile watched/ratings —
    // bidirectional, additive, so episodes you marked on another device
    // show up here and items you watched locally before signing in get
    // pushed up.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Unconditional and first: recovers watched marks stranded in the
      // legacy manual-watched store. Must run before the TMDB reconcile so
      // the recovered marks are part of the local set that gets pushed up,
      // rather than being seen as absent and unmarked by the pull step.
      await migrateManualWatchedMarks(ref);
      if (!mounted) return;
      if (ref.read(tmdbSessionProvider) != null) {
        ref.read(favoritesProvider.notifier).syncFromTmdb();
        ref.read(watchlistProvider.notifier).syncFromTmdb();
        reconcileWatchedWithTmdb(ref);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(currentTabIndexProvider);
    final connectionState = ref.watch(connection_provider.connectionProvider);
    final isWideScreen = context.isTabletOrLarger;

    // Watch counts for navigation badges
    final activeDownloadsCount = ref.watch(activeDownloadsCountProvider);
    final erroredCount = ref.watch(erroredTorrentsCountProvider);

    // Calendar badge: today's episodes or active auto-download
    final todayEpCount = ref.watch(todayEpisodesCountProvider);
    final autoDownloadState = ref.watch(autoDownloadProvider);
    final showCalendarDot =
        todayEpCount > 0 || autoDownloadState.downloadQueue.isNotEmpty;
    final calendarDotPulse = autoDownloadState.isProcessing;

    // ── Global streaming safety net ────────────────────────────────────────
    // If a *foreground* session becomes ready while its originating screen
    // is gone, this listener opens the player via the root navigator.
    // Next-episode prefetch passes makeActive: false so it never lands
    // here and cannot replace the episode still playing.
    ref.listen<StreamingSession?>(activeStreamingSessionProvider, (
      previous,
      next,
    ) {
      if (next == null) return;
      // Only fire on the transition into ready/playing, not on every rebuild
      final wasReady = previous?.isReady ?? false;
      if (!wasReady && next.isReady && next.videoFile != null) {
        rootNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => VideoPlayerScreen(
              file: next.videoFile!,
              showImdbId: next.showImdbId,
              movieImdbId: next.movieImdbId,
              isStreaming: true,
              streamingTorrentHash: next.torrentHash,
              streamingFileIndex: next.selectedFileIndex,
              streamingProxyUrl: next.streamUrl,
              initialBufferedRatio: next.bufferProgress,
              streamingSessionId: next.id,
            ),
          ),
        );
      }
    });

    return Scaffold(
      appBar: _buildAppBar(currentIndex, connectionState),
      body: Row(
        children: [
          // MediaHub-styled sidebar for wider screens
          if (isWideScreen)
            MediaHubSidebar(
              currentIndex: currentIndex,
              collapsed: _sidebarCollapsed,
              onToggleCollapse: () =>
                  setState(() => _sidebarCollapsed = !_sidebarCollapsed),
              onAddTorrent: () =>
                  _handleAddTorrentAction(context, connectionState),
              brandSubtitle: connectionState.isConnected
                  ? 'CONNECTED'
                  : 'OFFLINE',
              onDestinationSelected: (index) {
                ref.read(currentTabIndexProvider.notifier).set(index);
              },
              items: [
                const SidebarItem(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  label: 'Home',
                ),
                SidebarItem(
                  icon: erroredCount > 0
                      ? Icons.warning_amber_rounded
                      : Icons.download_outlined,
                  selectedIcon: erroredCount > 0
                      ? Icons.warning_amber_rounded
                      : Icons.download_rounded,
                  label: 'Transfers',
                  badge: activeDownloadsCount,
                  errorBadge: erroredCount > 0,
                ),
                const SidebarItem(
                  icon: Icons.live_tv_outlined,
                  selectedIcon: Icons.live_tv_rounded,
                  label: 'TV Shows',
                ),
                const SidebarItem(
                  icon: Icons.movie_outlined,
                  selectedIcon: Icons.movie_rounded,
                  label: 'Movies',
                ),
                const SidebarItem(
                  icon: Icons.video_library_outlined,
                  selectedIcon: Icons.video_library_rounded,
                  label: 'Library',
                ),
                SidebarItem(
                  icon: Icons.calendar_month_outlined,
                  selectedIcon: Icons.calendar_month_rounded,
                  label: 'Calendar',
                  dot: showCalendarDot,
                  dotPulse: calendarDotPulse,
                ),
                const SidebarItem(
                  icon: Icons.favorite_outline_rounded,
                  selectedIcon: Icons.favorite_rounded,
                  label: 'Favorites',
                ),
              ],
            ),
          // Main content — fade between tabs while keeping all screens alive
          Expanded(
            child: _FadeIndexedStack(index: currentIndex, children: _screens),
          ),
        ],
      ),
      // Bottom Navigation Bar for mobile
      bottomNavigationBar: isWideScreen
          ? null
          : NavigationBar(
              selectedIndex: currentIndex,
              onDestinationSelected: (index) {
                ref.read(currentTabIndexProvider.notifier).set(index);
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: NavBadge(
                    count: activeDownloadsCount,
                    isError: erroredCount > 0,
                    child: Icon(
                      erroredCount > 0
                          ? Icons.warning_amber_rounded
                          : Icons.download_outlined,
                    ),
                  ),
                  selectedIcon: NavBadge(
                    count: activeDownloadsCount,
                    isError: erroredCount > 0,
                    child: Icon(
                      erroredCount > 0
                          ? Icons.warning_amber_rounded
                          : Icons.download_rounded,
                    ),
                  ),
                  label: 'Transfers',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.live_tv_outlined),
                  selectedIcon: Icon(Icons.live_tv_rounded),
                  label: 'TV Shows',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.movie_outlined),
                  selectedIcon: Icon(Icons.movie_rounded),
                  label: 'Movies',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library_rounded),
                  label: 'Library',
                ),
                NavigationDestination(
                  icon: NavDot(
                    isVisible: showCalendarDot,
                    pulseAnimation: calendarDotPulse,
                    child: const Icon(Icons.calendar_month_outlined),
                  ),
                  selectedIcon: NavDot(
                    isVisible: showCalendarDot,
                    pulseAnimation: calendarDotPulse,
                    child: const Icon(Icons.calendar_month_rounded),
                  ),
                  label: 'Calendar',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.favorite_outline_rounded),
                  selectedIcon: Icon(Icons.favorite_rounded),
                  label: 'Favorites',
                ),
              ],
            ),
      floatingActionButton: !isWideScreen && currentIndex == 1
          ? FloatingActionButton.extended(
              onPressed: () =>
                  _handleAddTorrentAction(context, connectionState),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Torrent'),
            )
          : null,
    );
  }

  Future<void> _handleAddTorrentAction(
    BuildContext context,
    connection_provider.ConnectionState connectionState,
  ) async {
    if (!connectionState.isConnected) {
      if (context.mounted) {
        AppSnackBar.showWarning(
          context,
          message: 'Connect to qBittorrent to add torrents',
        );
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
      }
      return;
    }

    await _showAddTorrentDialog(context);
  }

  Future<void> _showAddTorrentDialog(BuildContext context) async {
    final result = await showAddTorrentDialog(context);
    if (result == true && context.mounted) {
      AppSnackBar.showSuccess(context, message: 'Torrent added successfully');
    }
  }

  PreferredSizeWidget _buildAppBar(
    int currentIndex,
    connection_provider.ConnectionState connectionState,
  ) {
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final activeDownloads = ref.watch(activeDownloadsCountProvider);
    final totalTorrents = ref.watch(torrentListProvider).torrents.length;

    String title;
    String? subtitle;
    final actions = <Widget>[];

    switch (currentIndex) {
      case 0:
        title = 'Home';
        subtitle = 'Ready to watch';
        break;
      case 1:
        title = 'Transfers';
        subtitle = totalTorrents > 0
            ? '$totalTorrents torrents · $activeDownloads active'
            : 'No torrents yet';
        // Aggregate dl/ul speeds — surfaced in the TopBar speed pill,
        // matching the design's `↓ 27.5 MB/s   ↑ 12.2 MB/s` widget.
        final torrents = ref.watch(torrentListProvider).torrents;
        final totalDl = torrents.fold<int>(0, (s, t) => s + t.dlspeed.toInt());
        final totalUl = torrents.fold<int>(0, (s, t) => s + t.upspeed.toInt());
        actions.addAll([
          TransfersSpeedPill(totalDl: totalDl, totalUl: totalUl),
          const ConnectionStatusWidget(),
          MediaHubIconButton(
            icon: isSelectionMode
                ? Icons.close_rounded
                : Icons.checklist_rounded,
            tooltip: isSelectionMode ? 'Exit selection' : 'Select multiple',
            active: isSelectionMode,
            onPressed: () {
              if (isSelectionMode) {
                ref.read(selectedTorrentHashesProvider.notifier).clear();
                ref.read(selectionModeProvider.notifier).disable();
              } else {
                ref.read(selectionModeProvider.notifier).enable();
              }
            },
          ),
        ]);
        break;
      case 2:
        title = 'TV Shows';
        subtitle = 'Trending, popular, top rated';
        break;
      case 3:
        title = 'Movies';
        subtitle = 'Curated for you';
        break;
      case 4:
        title = 'Library';
        subtitle = 'Your downloaded library';
        actions.add(
          MediaHubIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Rescan for new videos',
            onPressed: () {
              ref.invalidate(localMediaScannerProvider);
              ref.invalidate(localMediaFilesProvider);
            },
          ),
        );
        break;
      case 5:
        title = 'Calendar';
        subtitle = 'Upcoming · airing this week';
        break;
      case 6:
        title = 'Favorites';
        subtitle = 'Your saved shows and movies';
        break;
      default:
        title = 'MediaHub';
    }

    // Settings lives at the rightmost position of the TopBar's
    // actions row — single source for global app actions.
    actions.add(
      MediaHubIconButton(
        icon: Icons.settings_outlined,
        tooltip: 'Settings',
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
      ),
    );

    return MediaHubTopBar(
      title: title,
      subtitle: subtitle,
      showSearch: false,
      actions: actions,
    );
  }
}

// ---------------------------------------------------------------------------
// Fade-animated IndexedStack — keeps all screens alive, fades between them
// ---------------------------------------------------------------------------

class _FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const _FadeIndexedStack({required this.index, required this.children});

  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 1.0, // start fully visible — no fade on first load
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
  }

  @override
  void didUpdateWidget(_FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _ctrl.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
