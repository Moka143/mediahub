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
import '../utils/feedback_utils.dart';
import '../widgets/add_torrent_dialog.dart';
import '../widgets/common/delete_confirmation_dialog.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/common/nav_badge.dart';
import '../widgets/common/responsive_layout.dart';
import '../widgets/connection_status_widget.dart';
import '../widgets/torrent_list_item.dart';
import 'calendar_screen.dart';
import 'favorites_screen.dart';
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
  // Keep screens alive when switching tabs
  final List<Widget> _screens = const [
    DownloadsScreen(),
    ShowsScreen(),
    MoviesScreen(),
    WatchScreen(),
    CalendarScreen(),
    FavoritesScreen(),
  ];

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
    final showCalendarDot = todayEpCount > 0 || autoDownloadState.downloadQueue.isNotEmpty;
    final calendarDotPulse = autoDownloadState.isProcessing;

    // ── Global streaming safety net ────────────────────────────────────────
    // If any session becomes ready while its originating screen is gone,
    // this listener catches it and opens the player via the root navigator.
    ref.listen<StreamingSession?>(activeStreamingSessionProvider,
        (previous, next) {
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
            ),
          ),
        );
      }
    });

    return Scaffold(
      appBar: _buildAppBar(currentIndex, connectionState),
      body: Row(
        children: [
          // Modern Navigation Rail for wider screens
          if (isWideScreen)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  right: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
              ),
              child: NavigationRail(
                selectedIndex: currentIndex,
                onDestinationSelected: (index) {
                  ref.read(currentTabIndexProvider.notifier).set(index);
                },
                backgroundColor: Colors.transparent,
                extended: MediaQuery.of(context).size.width > 1100,
                minWidth: 72,
                minExtendedWidth: 180,
                labelType: MediaQuery.of(context).size.width > 1100
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.selected,
                useIndicator: true,
                indicatorColor: Theme.of(context).colorScheme.primaryContainer,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  child: MediaQuery.of(context).size.width > 1100
                      ? Tooltip(
                          message: connectionState.isConnected
                              ? 'Add torrent'
                              : 'Connect to qBittorrent to add torrents',
                          child: FilledButton.icon(
                            onPressed: () => _handleAddTorrentAction(
                              context,
                              connectionState,
                            ),
                            icon: const Icon(Icons.add_rounded, size: 20),
                            label: const Text('Add'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.lg,
                                vertical: AppSpacing.md,
                              ),
                            ),
                          ),
                        )
                      : Tooltip(
                          message: connectionState.isConnected
                              ? 'Add torrent'
                              : 'Connect to qBittorrent to add torrents',
                          child: FloatingActionButton.small(
                            onPressed: () => _handleAddTorrentAction(
                              context,
                              connectionState,
                            ),
                            elevation: 0,
                            child: const Icon(Icons.add_rounded),
                          ),
                        ),
                ),
                destinations: [
                  NavigationRailDestination(
                    icon: NavBadge(
                      count: activeDownloadsCount,
                      isError: erroredCount > 0,
                      child: Icon(
                        erroredCount > 0 ? Icons.warning_amber_rounded : Icons.download_outlined,
                      ),
                    ),
                    selectedIcon: NavBadge(
                      count: activeDownloadsCount,
                      isError: erroredCount > 0,
                      child: Icon(
                        erroredCount > 0 ? Icons.warning_amber_rounded : Icons.download_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    label: const Text('Transfers'),
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.live_tv_outlined),
                    selectedIcon: Icon(
                      Icons.live_tv_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    label: const Text('TV Shows'),
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.movie_outlined),
                    selectedIcon: Icon(
                      Icons.movie_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    label: const Text('Movies'),
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.video_library_outlined),
                    selectedIcon: Icon(
                      Icons.video_library_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    label: const Text('Library'),
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: NavDot(
                      isVisible: showCalendarDot,
                      pulseAnimation: calendarDotPulse,
                      child: const Icon(Icons.calendar_month_outlined),
                    ),
                    selectedIcon: NavDot(
                      isVisible: showCalendarDot,
                      pulseAnimation: calendarDotPulse,
                      child: Icon(
                        Icons.calendar_month_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    label: const Text('Calendar'),
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.favorite_outline_rounded),
                    selectedIcon: Icon(
                      Icons.favorite_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    label: const Text('Favorites'),
                    padding: const EdgeInsets.symmetric(
                      vertical: AppSpacing.xs,
                    ),
                  ),
                ],
              ),
            ),
          // Main content — fade between tabs while keeping all screens alive
          Expanded(
            child: _FadeIndexedStack(
              index: currentIndex,
              children: _screens,
            ),
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
                NavigationDestination(
                  icon: NavBadge(
                    count: activeDownloadsCount,
                    isError: erroredCount > 0,
                    child: Icon(
                      erroredCount > 0 ? Icons.warning_amber_rounded : Icons.download_outlined,
                    ),
                  ),
                  selectedIcon: NavBadge(
                    count: activeDownloadsCount,
                    isError: erroredCount > 0,
                    child: Icon(
                      erroredCount > 0 ? Icons.warning_amber_rounded : Icons.download_rounded,
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
      floatingActionButton: !isWideScreen && currentIndex == 0
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
    String title;
    List<Widget> actions = [];
    final isSelectionMode = ref.watch(isSelectionModeProvider);

    switch (currentIndex) {
      case 0:
        title = 'Transfers';
        actions = [
          const ConnectionStatusWidget(),
          const SizedBox(width: AppSpacing.sm),
          IconButton(
            icon: Icon(
              isSelectionMode ? Icons.close_rounded : Icons.checklist_rounded,
            ),
            tooltip: isSelectionMode ? 'Exit selection' : 'Select multiple',
            onPressed: () {
              if (isSelectionMode) {
                ref.read(selectedTorrentHashesProvider.notifier).clear();
                ref.read(selectionModeProvider.notifier).disable();
              } else {
                ref.read(selectionModeProvider.notifier).enable();
              }
            },
          ),
          const SizedBox(width: AppSpacing.sm),
        ];
        break;
      case 1:
        title = 'TV Shows';
        break;
      case 2:
        title = 'Movies';
        break;
      case 3:
        title = 'My Library';
        actions = [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              ref.invalidate(localMediaScannerProvider);
              ref.invalidate(localMediaFilesProvider);
            },
            tooltip: 'Rescan for new videos',
          ),
          const SizedBox(width: AppSpacing.sm),
        ];
        break;
      case 4:
        title = 'Calendar';
        break;
      case 5:
        title = 'Favorites';
        break;
      default:
        title = 'Torrent Client';
    }

    actions.add(
      IconButton(
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
        tooltip: 'Settings',
      ),
    );
    actions.add(const SizedBox(width: AppSpacing.sm));

    return AppBar(title: Text(title), actions: actions);
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
    final currentSort = ref.watch(currentSortProvider);
    final sortAscending = ref.watch(sortAscendingProvider);
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

        // Search bar
        if (connectionState.isConnected)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenPadding,
              AppSpacing.sm,
              AppSpacing.screenPadding,
              AppSpacing.xs,
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search torrents',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Clear search',
                        onPressed: () {
                          ref.read(torrentSearchQueryProvider.notifier).clear();
                          _searchController.clear();
                        },
                      )
                    : null,
              ),
              onChanged: (value) {
                ref.read(torrentSearchQueryProvider.notifier).set(value);
              },
            ),
          ),

        // Filter and sort bar
        if (connectionState.isConnected)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxWidth < 450;
                final isStacked = constraints.maxWidth < 720;

                if (isCompact) {
                  // Ultra-compact layout: dropdowns for both filter and sort
                  return Row(
                    children: [
                      // Filter dropdown
                      Expanded(
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<TorrentFilter>(
                              value: currentFilter,
                              isExpanded: true,
                              icon: const Icon(
                                Icons.filter_list_rounded,
                                size: 18,
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                              items: TorrentFilter.values.map((filter) {
                                final count = _getFilterCount(
                                  torrentState.torrents,
                                  filter,
                                );
                                return DropdownMenuItem(
                                  value: filter,
                                  child: Text(
                                    '${filter.label} ($count)',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                );
                              }).toList(),
                              onChanged: (filter) {
                                if (filter != null) {
                                  ref
                                      .read(currentFilterProvider.notifier)
                                      .set(filter);
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      // Sort dropdown
                      Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<TorrentSort>(
                            value: currentSort,
                            icon: Icon(
                              sortAscending
                                  ? Icons.arrow_upward_rounded
                                  : Icons.arrow_downward_rounded,
                              size: 18,
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                            items: TorrentSort.values.map((sort) {
                              return DropdownMenuItem(
                                value: sort,
                                child: Text(
                                  sort.label,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              );
                            }).toList(),
                            onChanged: (sort) {
                              if (sort != null) {
                                if (sort == currentSort) {
                                  // Toggle direction if same sort selected
                                  ref
                                      .read(sortAscendingProvider.notifier)
                                      .toggle();
                                } else {
                                  ref
                                      .read(currentSortProvider.notifier)
                                      .set(sort);
                                }
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  );
                }

                final filterChips = Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: TorrentFilter.values.map((filter) {
                    final isSelected = filter == currentFilter;
                    final count = _getFilterCount(
                      torrentState.torrents,
                      filter,
                    );
                    return FilterChip(
                      label: Text('${filter.label} ($count)'),
                      selected: isSelected,
                      onSelected: (_) {
                        ref.read(currentFilterProvider.notifier).set(filter);
                      },
                    );
                  }).toList(),
                );

                final sortControls = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<TorrentSort>(
                      initialValue: currentSort,
                      onSelected: (sort) {
                        ref.read(currentSortProvider.notifier).set(sort);
                      },
                      itemBuilder: (context) => TorrentSort.values.map((sort) {
                        return PopupMenuItem(
                          value: sort,
                          child: Row(
                            children: [
                              if (sort == currentSort)
                                Icon(
                                  sortAscending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: AppIconSize.sm,
                                )
                              else
                                const SizedBox(width: AppIconSize.sm),
                              const SizedBox(width: AppSpacing.sm),
                              Text(sort.label),
                            ],
                          ),
                        );
                      }).toList(),
                      child: Chip(
                        avatar: Icon(
                          sortAscending
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          size: AppIconSize.sm,
                        ),
                        label: Text(currentSort.label),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        sortAscending
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                      ),
                      onPressed: () {
                        ref.read(sortAscendingProvider.notifier).toggle();
                      },
                      tooltip: sortAscending
                          ? 'Sort Descending'
                          : 'Sort Ascending',
                    ),
                  ],
                );

                if (isStacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      filterChips,
                      const SizedBox(height: AppSpacing.sm),
                      Align(
                        alignment: Alignment.centerRight,
                        child: sortControls,
                      ),
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: filterChips),
                    const SizedBox(width: AppSpacing.sm),
                    sortControls,
                  ],
                );
              },
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
            // Navigate to Browse tab
            ref.read(currentTabIndexProvider.notifier).set(1);
          },
          icon: const Icon(Icons.tv),
          label: const Text('Browse Shows'),
        ),
      );
    }

    final selectedHash = ref.watch(selectedTorrentHashProvider);
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final selectedHashes = ref.watch(selectedTorrentHashesProvider);

    return RefreshIndicator(
      onRefresh: () => ref.read(torrentListProvider.notifier).refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: torrents.length,
        itemBuilder: (context, index) {
          final torrent = torrents[index];
          final isSelected = isSelectionMode
              ? selectedHashes.contains(torrent.hash)
              : isInMasterDetail && torrent.hash == selectedHash;
          // Use swipeable version on mobile, regular on desktop master-detail
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
      ),
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
        AppSnackBar.showInfo(
          context,
          message: 'Paused: ${torrent.name}',
        );
      } else {
        AppSnackBar.showError(
          context,
          message: 'Failed to pause torrent',
        );
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
        AppSnackBar.showSuccess(
          context,
          message: 'Resumed: ${torrent.name}',
        );
      } else {
        AppSnackBar.showError(
          context,
          message: 'Failed to resume torrent',
        );
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
          AppSnackBar.showSuccess(
            context,
            message: 'Deleted: ${torrent.name}',
          );
        } else {
          AppSnackBar.showError(
            context,
            message: 'Failed to delete torrent',
          );
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
