import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/torrent.dart';
import '../providers/settings_provider.dart';
import '../providers/torrent_provider.dart';
import '../providers/connection_provider.dart';
import '../utils/constants.dart';
import '../widgets/add_torrent_dialog.dart';
import '../widgets/connection_status_widget.dart';
import '../widgets/torrent_list_item.dart';
import '../widgets/common/delete_confirmation_dialog.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import 'settings_screen.dart';
import 'torrent_details_screen.dart';

/// Main home screen showing the list of torrents
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(connectionProvider);
    final torrentState = ref.watch(torrentListProvider);
    final filteredTorrents = ref.watch(filteredTorrentsProvider);
    final currentFilter = ref.watch(currentFilterProvider);
    final currentSort = ref.watch(currentSortProvider);
    final sortAscending = ref.watch(sortAscendingProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MediaHub'),
        actions: [
          const ConnectionStatusWidget(),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: connectionState.isConnected
                ? () => ref.read(torrentListProvider.notifier).refresh()
                : null,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
            tooltip: 'Settings',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Connection banner (shown when disconnected)
          ConnectionBanner(
            onOpenSettings: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),

          // Filter and sort bar
          if (connectionState.isConnected)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.screenPadding,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  // Filter chips
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: TorrentFilter.values.map((filter) {
                          final isSelected = filter == currentFilter;
                          final count = _getFilterCount(
                            torrentState.torrents,
                            filter,
                          );
                          return Padding(
                            padding: const EdgeInsets.only(
                              right: AppSpacing.sm,
                            ),
                            child: FilterChip(
                              label: Text('${filter.label} ($count)'),
                              selected: isSelected,
                              onSelected: (_) {
                                ref
                                    .read(currentFilterProvider.notifier)
                                    .set(filter);
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),

                  // Sort dropdown
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

                  // Toggle sort direction
                  IconButton(
                    icon: Icon(
                      sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    ),
                    onPressed: () {
                      ref.read(sortAscendingProvider.notifier).toggle();
                    },
                    tooltip: sortAscending
                        ? 'Sort Descending'
                        : 'Sort Ascending',
                  ),
                ],
              ),
            ),

          // Torrent list
          Expanded(
            child: _buildTorrentList(context, filteredTorrents, torrentState),
          ),
        ],
      ),
      floatingActionButton: connectionState.isConnected
          ? FloatingActionButton.extended(
              onPressed: () => _showAddTorrentDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('Add Torrent'),
            )
          : null,
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

  Widget _buildTorrentList(
    BuildContext context,
    List<Torrent> torrents,
    TorrentListState state,
  ) {
    if (state.isLoading && torrents.isEmpty) {
      return const LoadingIndicator(message: 'Loading torrents...');
    }

    if (state.error != null && torrents.isEmpty) {
      return EmptyState.error(
        message: state.error!,
        onRetry: () => ref.read(torrentListProvider.notifier).refresh(),
      );
    }

    if (torrents.isEmpty) {
      return EmptyState.noData(
        icon: Icons.cloud_download_outlined,
        title: 'No torrents',
        subtitle: 'Click the + button to add a torrent',
        action: FilledButton.icon(
          onPressed: () => _showAddTorrentDialog(context),
          icon: const Icon(Icons.add),
          label: const Text('Add Torrent'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(torrentListProvider.notifier).refresh(),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: torrents.length,
        itemBuilder: (context, index) {
          final torrent = torrents[index];
          return TorrentListItem(
            torrent: torrent,
            onTap: () => _openTorrentDetails(context, torrent),
            onPause: () => _pauseTorrent(torrent),
            onResume: () => _resumeTorrent(torrent),
            onDelete: () => _showDeleteDialog(context, torrent),
          );
        },
      ),
    );
  }

  void _openTorrentDetails(BuildContext context, Torrent torrent) {
    ref.read(selectedTorrentHashProvider.notifier).set(torrent.hash);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TorrentDetailsScreen(torrentHash: torrent.hash),
      ),
    );
  }

  Future<void> _pauseTorrent(Torrent torrent) async {
    final success = await ref
        .read(torrentListProvider.notifier)
        .pauseTorrent(torrent.hash);
    if (!success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to pause torrent')));
    }
  }

  Future<void> _resumeTorrent(Torrent torrent) async {
    final success = await ref
        .read(torrentListProvider.notifier)
        .resumeTorrent(torrent.hash);
    if (!success && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to resume torrent')));
    }
  }

  Future<void> _showDeleteDialog(BuildContext context, Torrent torrent) async {
    final result = await DeleteConfirmationDialog.showForTorrent(
      context: context,
      torrentName: torrent.name,
    );

    if (result != null && result.confirmed) {
      final success = await ref
          .read(torrentListProvider.notifier)
          .deleteTorrent(torrent.hash, deleteFiles: result.deleteFiles);

      if (!success && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete torrent')),
        );
      }
    }
  }

  Future<void> _showAddTorrentDialog(BuildContext context) async {
    final result = await showAddTorrentDialog(context);
    if (result == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Torrent added successfully')),
      );
    }
  }
}
