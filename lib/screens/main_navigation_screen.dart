import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../design/app_tokens.dart';
import '../design/app_theme.dart';
import '../models/torrent.dart';
import '../providers/auto_download_provider.dart';
import '../providers/connection_provider.dart' as connection_provider;
import '../providers/local_media_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/streaming_provider.dart';
import '../providers/torrent_provider.dart';
import '../services/streaming_service.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../utils/feedback_utils.dart';
import '../widgets/add_torrent_dialog.dart';
import '../widgets/common/delete_confirmation_dialog.dart';
import '../design/app_colors.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/common/mediahub_chip.dart';
import '../widgets/common/mediahub_sidebar.dart';
import '../widgets/common/mediahub_topbar.dart';
import '../widgets/common/nav_badge.dart';
import '../widgets/common/responsive_layout.dart';
import '../widgets/connection_status_widget.dart';
import '../widgets/mediahub_torrent_row.dart';
import '../widgets/torrent_list_item.dart';
import 'calendar_screen.dart';
import 'favorites_screen.dart';
import 'mediahub_home_screen.dart';
import 'movies_screen.dart';
import 'settings_screen.dart';
import 'shows_screen.dart';
import 'torrent_details_screen.dart';
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
    // If any session becomes ready while its originating screen is gone,
    // this listener catches it and opens the player via the root navigator.
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Connect to qBittorrent to add torrents'),
            behavior: SnackBarBehavior.floating,
          ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Torrent added successfully'),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(AppSpacing.screenPadding),
        ),
      );
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
          _TransfersSpeedPill(totalDl: totalDl, totalUl: totalUl),
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

/// The downloads screen (extracted from old HomeScreen)
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  @override
  Widget build(BuildContext context) {
    // Use master-detail layout on desktop screens
    return ResponsiveLayout(
      mobile: const _DownloadsContent(),
      desktop: const _DownloadsMasterDetail(),
    );
  }
}

/// Master-detail layout for downloads on wider screens
class _DownloadsMasterDetail extends ConsumerWidget {
  const _DownloadsMasterDetail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedHash = ref.watch(selectedTorrentHashProvider);

    return Row(
      children: [
        // Master - Torrent List (40% width, min 300px)
        SizedBox(
          width: (MediaQuery.of(context).size.width * 0.35).clamp(300.0, 500.0),
          child: const _DownloadsContent(isInMasterDetail: true),
        ),
        const VerticalDivider(width: 1, thickness: 1),
        // Detail - Torrent Details (remaining width)
        Expanded(
          child: selectedHash != null
              ? TorrentDetailsScreen(torrentHash: selectedHash, embedded: true)
              : const _SelectTorrentPrompt(),
        ),
      ],
    );
  }
}

/// Prompt shown when no torrent is selected in master-detail layout
class _SelectTorrentPrompt extends StatelessWidget {
  const _SelectTorrentPrompt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.touch_app_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Select a torrent to view details',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

/// The actual downloads content (moved from HomeScreen)
class _DownloadsContent extends ConsumerStatefulWidget {
  /// Whether this is used in master-detail layout (affects tap behavior)
  final bool isInMasterDetail;

  const _DownloadsContent({this.isInMasterDetail = false});

  @override
  ConsumerState<_DownloadsContent> createState() => _DownloadsContentState();
}

class _DownloadsContentState extends ConsumerState<_DownloadsContent> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(torrentSearchQueryProvider),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(torrentSearchQueryProvider);
    if (_searchController.text != searchQuery) {
      _searchController.value = _searchController.value.copyWith(
        text: searchQuery,
        selection: TextSelection.collapsed(offset: searchQuery.length),
        composing: TextRange.empty,
      );
    }
    final connectionState = ref.watch(connection_provider.connectionProvider);
    final torrentState = ref.watch(torrentListProvider);
    final filteredTorrents = ref.watch(filteredTorrentsProvider);
    final currentFilter = ref.watch(currentFilterProvider);
    // Sort lives in the column-header strip below; no need to read it
    // here — _TorrentListBuilder reads it directly when it renders.
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final selectedHashes = ref.watch(selectedTorrentHashesProvider);

    return Column(
      children: [
        // Connection banner (shown when disconnected)
        ConnectionBanner(
          onOpenSettings: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),

        // Selection bar (multi-select)
        if (isSelectionMode)
          _SelectionBar(
            selectedCount: selectedHashes.length,
            totalCount: filteredTorrents.length,
            onClear: () =>
                ref.read(selectedTorrentHashesProvider.notifier).clear(),
            onExit: () => ref.read(selectionModeProvider.notifier).disable(),
            onSelectAll: () => ref
                .read(selectedTorrentHashesProvider.notifier)
                .addAll(filteredTorrents.map((torrent) => torrent.hash)),
            onPause: () => _pauseSelected(context, ref, selectedHashes),
            onResume: () => _resumeSelected(context, ref, selectedHashes),
            onDelete: () => _deleteSelected(context, ref, selectedHashes),
          ),

        // MediaHub-style filter row — status filter chips on the left
        // (with status dot + count per chip) and a tight 220px search
        // pill on the right. Replaces the previous separate search
        // TextField + filter+sort dropdowns. Sort happens via the
        // sortable column header strip below — no redundant dropdown.
        if (connectionState.isConnected)
          Container(
            decoration: const BoxDecoration(
              color: AppColors.bgPage,
              border: Border(
                bottom: BorderSide(color: Color(0x0FFFFFFF), width: 1),
              ),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxl,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final filter in TorrentFilter.values) ...[
                          MediaHubFilterChip(
                            label: filter.label,
                            selected: filter == currentFilter,
                            count: _getFilterCount(
                              torrentState.torrents,
                              filter,
                            ),
                            dotColor: _filterAccent(filter),
                            accentColor:
                                _filterAccent(filter) ?? AppColors.seedColor,
                            onTap: () => ref
                                .read(currentFilterProvider.notifier)
                                .set(filter),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                _TransfersSearchPill(
                  controller: _searchController,
                  onChanged: (v) =>
                      ref.read(torrentSearchQueryProvider.notifier).set(v),
                ),
              ],
            ),
          ),

        // Torrent list
        Expanded(
          child: _TorrentListBuilder(
            torrents: filteredTorrents,
            state: torrentState,
            isInMasterDetail: widget.isInMasterDetail,
            searchQuery: searchQuery,
          ),
        ),
      ],
    );
  }

  /// Pick the accent color for a filter chip — matches the MediaHub
  /// status palette so the chip dot reads as the same identity as the
  /// row state dot. Returns null for `all` (uses neutral accent).
  Color? _filterAccent(TorrentFilter filter) {
    switch (filter) {
      case TorrentFilter.downloading:
        return AppColors.downloading;
      case TorrentFilter.seeding:
        return AppColors.seeding;
      case TorrentFilter.completed:
        return AppColors.success;
      case TorrentFilter.paused:
        return AppColors.paused;
      case TorrentFilter.errored:
        return AppColors.errorState;
      case TorrentFilter.active:
      case TorrentFilter.inactive:
      case TorrentFilter.all:
        return null;
    }
  }

  int _getFilterCount(List<Torrent> torrents, TorrentFilter filter) {
    switch (filter) {
      case TorrentFilter.all:
        return torrents.length;
      case TorrentFilter.downloading:
        return torrents.where((t) => t.isDownloading).length;
      case TorrentFilter.seeding:
        return torrents.where((t) => t.isSeeding).length;
      case TorrentFilter.completed:
        return torrents.where((t) => t.isCompleted).length;
      case TorrentFilter.paused:
        return torrents.where((t) => t.isPaused).length;
      case TorrentFilter.active:
        return torrents.where((t) => t.isActive).length;
      case TorrentFilter.inactive:
        return torrents.where((t) => !t.isActive).length;
      case TorrentFilter.errored:
        return torrents.where((t) => t.hasError).length;
    }
  }

  Future<void> _pauseSelected(
    BuildContext context,
    WidgetRef ref,
    Set<String> selectedHashes,
  ) async {
    if (selectedHashes.isEmpty) return;
    final success = await ref
        .read(torrentListProvider.notifier)
        .pauseTorrents(selectedHashes.toList());
    if (success) {
      ref.read(selectedTorrentHashesProvider.notifier).clear();
      ref.read(selectionModeProvider.notifier).disable();
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to pause selected torrents')),
      );
    }
  }

  Future<void> _resumeSelected(
    BuildContext context,
    WidgetRef ref,
    Set<String> selectedHashes,
  ) async {
    if (selectedHashes.isEmpty) return;
    final success = await ref
        .read(torrentListProvider.notifier)
        .resumeTorrents(selectedHashes.toList());
    if (success) {
      ref.read(selectedTorrentHashesProvider.notifier).clear();
      ref.read(selectionModeProvider.notifier).disable();
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to resume selected torrents')),
      );
    }
  }

  Future<void> _deleteSelected(
    BuildContext context,
    WidgetRef ref,
    Set<String> selectedHashes,
  ) async {
    if (selectedHashes.isEmpty) return;

    final result = await DeleteConfirmationDialog.showForTorrents(
      context: context,
      torrentCount: selectedHashes.length,
    );

    if (result == null || !result.confirmed) return;

    final success = await ref
        .read(torrentListProvider.notifier)
        .deleteTorrents(
          selectedHashes.toList(),
          deleteFiles: result.deleteFiles,
        );

    if (success) {
      ref.read(selectedTorrentHashesProvider.notifier).clear();
      ref.read(selectionModeProvider.notifier).disable();
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete selected torrents')),
      );
    }
  }
}

/// Aggregate `↓ X MB/s · ↑ Y MB/s` pill rendered in the TopBar
/// actions row on the Transfers tab. Matches the design's status
/// widget on `screen-transfers.jsx`.
class _TransfersSpeedPill extends StatelessWidget {
  const _TransfersSpeedPill({required this.totalDl, required this.totalUl});

  final int totalDl;
  final int totalUl;

  @override
  Widget build(BuildContext context) {
    Widget speedRow({
      required Color color,
      required String arrow,
      required int bytes,
    }) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: color.withAlpha(120), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Text(
            arrow,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF7A7A92),
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 2),
          Text(
            Formatters.formatSpeed(bytes),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF4F4F8),
              fontFamily: 'monospace',
            ),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: const Color(0x0FFFFFFF)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          speedRow(color: AppColors.downloading, arrow: '↓', bytes: totalDl),
          Container(
            width: 1,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            color: const Color(0x0FFFFFFF),
          ),
          speedRow(color: AppColors.seeding, arrow: '↑', bytes: totalUl),
        ],
      ),
    );
  }
}

/// Compact search pill used in the Transfers filter row — matches
/// the design's right-side 220px search field on the Transfers screen.
class _TransfersSearchPill extends StatelessWidget {
  const _TransfersSearchPill({
    required this.controller,
    required this.onChanged,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        border: Border.all(color: const Color(0x0FFFFFFF)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 12, color: Color(0xFF7A7A92)),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              cursorColor: AppColors.seedColor,
              style: const TextStyle(fontSize: 12, color: Color(0xFFF4F4F8)),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: 'Filter by name…',
                hintStyle: TextStyle(fontSize: 12, color: Color(0x66B4B4C8)),
                filled: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TorrentListBuilder extends ConsumerWidget {
  final List<Torrent> torrents;
  final TorrentListState state;
  final bool isInMasterDetail;
  final String searchQuery;

  const _TorrentListBuilder({
    required this.torrents,
    required this.state,
    this.isInMasterDetail = false,
    this.searchQuery = '',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.isLoading && torrents.isEmpty) {
      // Show skeleton loading for better UX
      return const TorrentSkeletonList(itemCount: 5);
    }

    if (state.error != null && torrents.isEmpty) {
      return EmptyState.error(
        message: state.error!,
        onRetry: () => ref.read(torrentListProvider.notifier).refresh(),
      );
    }

    if (torrents.isEmpty) {
      if (searchQuery.trim().isNotEmpty) {
        return EmptyState.noResults(
          title: 'No torrents match "$searchQuery"',
          subtitle: 'Try a different name or clear the search',
          action: FilledButton.icon(
            onPressed: () =>
                ref.read(torrentSearchQueryProvider.notifier).clear(),
            icon: const Icon(Icons.close_rounded),
            label: const Text('Clear Search'),
          ),
        );
      }
      return EmptyState.noData(
        icon: Icons.cloud_download_outlined,
        title: 'No torrents yet',
        subtitle: 'Discover shows and start downloading episodes',
        action: FilledButton.icon(
          onPressed: () {
            // Navigate to TV Shows tab (index 2 — Home is now 0).
            ref.read(currentTabIndexProvider.notifier).set(2);
          },
          icon: const Icon(Icons.tv),
          label: const Text('Browse Shows'),
        ),
      );
    }

    final selectedHash = ref.watch(selectedTorrentHashProvider);
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final selectedHashes = ref.watch(selectedTorrentHashesProvider);
    final useDenseRows = context.isTabletOrLarger;
    final currentSort = ref.watch(currentSortProvider);
    final sortAscending = ref.watch(sortAscendingProvider);

    final list = ListView.builder(
      padding: EdgeInsets.only(bottom: useDenseRows ? 0 : 80),
      itemCount: torrents.length,
      itemBuilder: (context, index) {
        final torrent = torrents[index];
        final isSelected = isSelectionMode
            ? selectedHashes.contains(torrent.hash)
            : isInMasterDetail && torrent.hash == selectedHash;
        if (useDenseRows) {
          return MediaHubTorrentRow(
            torrent: torrent,
            selected: isSelected,
            compact: isInMasterDetail,
            onTap: () {
              if (isSelectionMode) {
                ref.read(selectionModeProvider.notifier).enable();
                ref
                    .read(selectedTorrentHashesProvider.notifier)
                    .toggle(torrent.hash);
              } else {
                _openTorrentDetails(context, ref, torrent);
              }
            },
            onLongPress: () {
              ref.read(selectionModeProvider.notifier).enable();
              ref
                  .read(selectedTorrentHashesProvider.notifier)
                  .toggle(torrent.hash);
            },
            onPause: () => _pauseTorrent(context, ref, torrent),
            onResume: () => _resumeTorrent(context, ref, torrent),
            onDelete: () => _showDeleteDialog(context, ref, torrent),
          );
        }
        return SwipeableTorrentListItem(
          torrent: torrent,
          selected: isSelected,
          enableSwipe: !isInMasterDetail && !isSelectionMode,
          onTap: () {
            if (isSelectionMode) {
              ref.read(selectionModeProvider.notifier).enable();
              ref
                  .read(selectedTorrentHashesProvider.notifier)
                  .toggle(torrent.hash);
            } else {
              _openTorrentDetails(context, ref, torrent);
            }
          },
          onLongPress: () {
            ref.read(selectionModeProvider.notifier).enable();
            ref
                .read(selectedTorrentHashesProvider.notifier)
                .toggle(torrent.hash);
          },
          onPause: () => _pauseTorrent(context, ref, torrent),
          onResume: () => _resumeTorrent(context, ref, torrent),
          onDelete: () => _showDeleteDialog(context, ref, torrent),
        );
      },
    );

    return RefreshIndicator(
      onRefresh: () => ref.read(torrentListProvider.notifier).refresh(),
      child: useDenseRows
          ? Column(
              children: [
                MediaHubTorrentHeader(
                  sortKey: currentSort,
                  ascending: sortAscending,
                  compact: isInMasterDetail,
                  onSortKeyTap: (k) {
                    if (currentSort == k) {
                      ref.read(sortAscendingProvider.notifier).toggle();
                    } else {
                      ref.read(currentSortProvider.notifier).set(k);
                    }
                  },
                ),
                Expanded(child: list),
              ],
            )
          : list,
    );
  }

  void _openTorrentDetails(
    BuildContext context,
    WidgetRef ref,
    Torrent torrent,
  ) {
    ref.read(selectedTorrentHashProvider.notifier).set(torrent.hash);
    // In master-detail mode, just select the torrent (detail pane updates automatically)
    // In mobile mode, navigate to the details screen
    if (!isInMasterDetail) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TorrentDetailsScreen(torrentHash: torrent.hash),
        ),
      );
    }
  }

  Future<void> _pauseTorrent(
    BuildContext context,
    WidgetRef ref,
    Torrent torrent,
  ) async {
    AppHaptics.lightImpact();
    final success = await ref
        .read(torrentListProvider.notifier)
        .pauseTorrent(torrent.hash);
    if (context.mounted) {
      if (success) {
        AppSnackBar.showInfo(context, message: 'Paused: ${torrent.name}');
      } else {
        AppSnackBar.showError(context, message: 'Failed to pause torrent');
      }
    }
  }

  Future<void> _resumeTorrent(
    BuildContext context,
    WidgetRef ref,
    Torrent torrent,
  ) async {
    AppHaptics.lightImpact();
    final success = await ref
        .read(torrentListProvider.notifier)
        .resumeTorrent(torrent.hash);
    if (context.mounted) {
      if (success) {
        AppSnackBar.showSuccess(context, message: 'Resumed: ${torrent.name}');
      } else {
        AppSnackBar.showError(context, message: 'Failed to resume torrent');
      }
    }
  }

  Future<void> _showDeleteDialog(
    BuildContext context,
    WidgetRef ref,
    Torrent torrent,
  ) async {
    final result = await DeleteConfirmationDialog.showForTorrent(
      context: context,
      torrentName: torrent.name,
    );

    if (result != null && result.confirmed) {
      AppHaptics.mediumImpact();
      final success = await ref
          .read(torrentListProvider.notifier)
          .deleteTorrent(torrent.hash, deleteFiles: result.deleteFiles);

      if (context.mounted) {
        if (success) {
          AppSnackBar.showSuccess(context, message: 'Deleted: ${torrent.name}');
        } else {
          AppSnackBar.showError(context, message: 'Failed to delete torrent');
        }
      }
    }
  }
}

class _SelectionBar extends StatelessWidget {
  final int selectedCount;
  final int totalCount;
  final VoidCallback onClear;
  final VoidCallback onExit;
  final VoidCallback onSelectAll;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;

  const _SelectionBar({
    required this.selectedCount,
    required this.totalCount,
    required this.onClear,
    required this.onExit,
    required this.onSelectAll,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = context.appColors;
    final hasSelection = selectedCount > 0;
    final canSelectAll = totalCount > 0 && selectedCount < totalCount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 520;
        final selectAllButton = isCompact
            ? IconButton(
                tooltip: 'Select all',
                onPressed: canSelectAll ? onSelectAll : null,
                icon: const Icon(Icons.select_all_rounded),
              )
            : TextButton.icon(
                onPressed: canSelectAll ? onSelectAll : null,
                icon: const Icon(
                  Icons.select_all_rounded,
                  size: AppIconSize.sm,
                ),
                label: const Text('Select all'),
              );

        return Container(
          margin: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenPadding,
            vertical: AppSpacing.sm,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
              color: theme.colorScheme.outline.withAlpha(AppOpacity.light),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.xs),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  Icons.checklist_rounded,
                  size: AppIconSize.sm,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '$selectedCount selected',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              selectAllButton,
              IconButton(
                tooltip: 'Pause',
                onPressed: hasSelection ? onPause : null,
                icon: const Icon(Icons.pause_rounded),
              ),
              IconButton(
                tooltip: 'Resume',
                onPressed: hasSelection ? onResume : null,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
              IconButton(
                tooltip: 'Delete',
                onPressed: hasSelection ? onDelete : null,
                color: appColors.errorState,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
              IconButton(
                tooltip: 'Exit selection',
                onPressed: () {
                  onClear();
                  onExit();
                },
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        );
      },
    );
  }
}
