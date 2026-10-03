import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/torrent.dart';
import '../providers/connection_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/torrent_provider.dart';
import '../utils/constants.dart';
import '../utils/formatters.dart';
import '../widgets/common/browse_search_pill.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/loading_state.dart';
import '../widgets/common/mediahub_chip.dart';
import '../widgets/connection_status_widget.dart';
import '../widgets/editorial/editorial.dart';
import '../widgets/mediahub_torrent_row.dart';
import '../widgets/transfers/transfer_actions.dart';
import '../widgets/transfers/transfers_selection.dart';
import 'settings_screen.dart';
import 'torrent_details_screen.dart';

/// From this width up, the details sit beside the list instead of opening as
/// their own page.
///
/// Measured on the Transfers area itself — the window minus the sidebar —
/// rather than the window, which is what the old 1200px window breakpoint
/// got wrong in both directions. The list needs about 400px for a readable
/// name column and the details about 600px for their stats and tabs.
const double kTransfersSplitViewMinWidth = 1000;

/// The Transfers screen: the engine's torrents, with their details.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(
      connectionProvider.select((c) => c.isConnected),
    );
    // While the engine is down the list is empty because nothing can be
    // asked, not because there is nothing — saying "No transfers yet" under
    // an error banner read as data loss.
    if (!connected) {
      return EngineOfflineState(onOpenSettings: () => _openSettings(context));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= kTransfersSplitViewMinWidth) {
          return _TransfersSplitView(width: constraints.maxWidth);
        }
        return const _TransfersList();
      },
    );
  }
}

void _openSettings(BuildContext context) => unawaited(
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
);

/// List and details side by side.
class _TransfersSplitView extends ConsumerWidget {
  const _TransfersSplitView({required this.width});

  final double width;

  /// The list's share of the width: enough for a readable name column,
  /// capped so a big window gives the extra room to the details.
  static const double _listMin = 400;
  static const double _listMax = 520;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final openHash = ref.watch(selectedTorrentHashProvider);
    final listWidth = (width * 0.4).clamp(_listMin, _listMax);

    return Row(
      children: [
        SizedBox(
          width: listWidth,
          child: const _TransfersList(inSplitView: true),
        ),
        const VerticalDivider(width: 1, thickness: 1, color: AppColors.line),
        Expanded(
          child: openHash == null
              ? const _SelectTransferPrompt()
              : TorrentDetailsScreen(torrentHash: openHash, embedded: true),
        ),
      ],
    );
  }
}

/// The details pane before anything is selected.
class _SelectTransferPrompt extends StatelessWidget {
  const _SelectTransferPrompt();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.ads_click_rounded,
            size: AppIconSize.xxl,
            color: AppColors.fg3,
          ),
          const SizedBox(height: AppSpacing.lg),
          // fg2: the old outline colour was 1.3:1 against the page.
          Text(
            'Select a transfer to see its details',
            textAlign: TextAlign.center,
            style: AppType.ui(size: AppType.sizeLead, color: AppColors.fg2),
          ),
        ],
      ),
    );
  }
}

/// Filter row, multi-selection bar and the list itself.
class _TransfersList extends ConsumerStatefulWidget {
  const _TransfersList({this.inSplitView = false});

  /// Beside the details pane: rows are compact and a click selects rather
  /// than pushing a page.
  final bool inSplitView;

  @override
  ConsumerState<_TransfersList> createState() => _TransfersListState();
}

class _TransfersListState extends ConsumerState<_TransfersList> {
  late final TextEditingController _searchController;

  /// Held so the provider→controller sync in [build] can tell whether the
  /// user is currently typing. See the guard there.
  final FocusNode _searchFocus = FocusNode();

  /// Lets Esc and ⌘A / Ctrl+A reach the list after a row was clicked — a
  /// click does not move keyboard focus by itself.
  final FocusNode _listFocus = FocusNode(debugLabel: 'Transfers list');

  /// Where a Shift-click range starts: the last row opened or toggled.
  String? _anchorHash;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(torrentSearchQueryProvider),
    );
  }

  @override
  void dispose() {
    _listFocus.dispose();
    _searchFocus.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Never rewrite the field while the user is in it. Assigning `.value`
  /// resets the selection to a collapsed caret at the end, and this screen
  /// rebuilds every 2 s from the torrent poll — so a rebuild landing between
  /// keystrokes would yank the caret and scramble what was being typed.
  /// Outside focus the sync still matters: it reflects a query cleared or
  /// set from elsewhere.
  void _syncSearchField(String query) {
    if (_searchFocus.hasFocus || _searchController.text == query) return;
    _searchController.value = _searchController.value.copyWith(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final searchQuery = ref.watch(torrentSearchQueryProvider);
    _syncSearchField(searchQuery);
    final listState = ref.watch(torrentListProvider);
    final visible = ref.watch(filteredTorrentsProvider);
    final selecting = ref.watch(isSelectionModeProvider);
    final checked = ref.watch(selectedTorrentHashesProvider);

    return Column(
      children: [
        if (selecting)
          _SelectionBar(
            selectedCount: checked.length,
            totalCount: visible.length,
            inset: _inset,
            onSelectAll: () => _checkAll(visible),
            onPause: () => unawaited(_pauseChecked(checked)),
            onResume: () => unawaited(_resumeChecked(checked)),
            onDelete: () => unawaited(_deleteChecked(checked)),
            onExit: _exitSelection,
          ),
        _FilterRow(
          torrents: listState.torrents,
          searchController: _searchController,
          searchFocus: _searchFocus,
          compact: widget.inSplitView,
        ),
        Expanded(
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              // Bound only while selecting, so Esc is not swallowed for
              // anything above the list the rest of the time.
              if (selecting)
                const SingleActivator(LogicalKeyboardKey.escape):
                    _exitSelection,
              SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: _isMac,
                control: !_isMac,
              ): () =>
                  _checkAll(visible),
            },
            child: Focus(
              focusNode: _listFocus,
              skipTraversal: true,
              child: _listBody(listState, visible, searchQuery),
            ),
          ),
        ),
      ],
    );
  }

  double get _inset => TransferColumn.inset(compact: widget.inSplitView);

  static bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

  Widget _listBody(
    TorrentListState listState,
    List<Torrent> visible,
    String searchQuery,
  ) {
    if (listState.isLoading && visible.isEmpty) {
      return const TorrentSkeletonList(itemCount: 5);
    }
    if (listState.error != null && visible.isEmpty) {
      return EmptyState.error(
        title: "Couldn't load your transfers",
        message: transferFailureReason(listState.error),
        onRetry: () =>
            unawaited(ref.read(torrentListProvider.notifier).refresh()),
      );
    }
    if (visible.isEmpty) {
      return _EmptyTransfers(
        searchQuery: searchQuery.trim(),
        hasTransfers: listState.torrents.isNotEmpty,
      );
    }

    final openHash = ref.watch(selectedTorrentHashProvider);
    final selecting = ref.watch(isSelectionModeProvider);
    final checked = ref.watch(selectedTorrentHashesProvider);
    final sort = ref.watch(currentSortProvider);
    final ascending = ref.watch(sortAscendingProvider);
    final ordered = [for (final torrent in visible) torrent.hash];

    return RefreshIndicator(
      onRefresh: () => ref.read(torrentListProvider.notifier).refresh(),
      child: Column(
        children: [
          MediaHubTorrentHeader(
            sortKey: sort,
            ascending: ascending,
            compact: widget.inSplitView,
            onSortKeyTap: (key) {
              if (sort == key) {
                ref.read(sortAscendingProvider.notifier).toggle();
              } else {
                ref.read(currentSortProvider.notifier).set(key);
              }
            },
          ),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final torrent = visible[index];
                final inSet = checked.contains(torrent.hash);
                return MediaHubTorrentRow(
                  key: ValueKey(torrent.hash),
                  torrent: torrent,
                  selected: selecting
                      ? inSet
                      : widget.inSplitView && torrent.hash == openHash,
                  checked: inSet,
                  compact: widget.inSplitView,
                  onTap: () => _onRowActivated(torrent, ordered),
                  onLongPress: () => _toggleChecked(torrent.hash),
                  onOpen: () => _openDetails(torrent),
                  onPause: () => unawaited(_pause(torrent)),
                  onResume: () => unawaited(_resume(torrent)),
                  onDelete: () => unawaited(_delete(torrent)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Opening and selecting ────────────────────────────────────────────

  /// A click, Enter or Space on a row. Shift extends the selection from the
  /// last row clicked; ⌘ (Ctrl on Windows and Linux) toggles one row; and
  /// during a selection a plain click toggles too.
  void _onRowActivated(Torrent torrent, List<String> ordered) {
    if (!_listFocus.hasFocus) _listFocus.requestFocus();
    final keys = HardwareKeyboard.instance;
    final wasSelecting = ref.read(isSelectionModeProvider);
    final intent = transfersClickIntent(
      selectionMode: wasSelecting,
      shiftHeld: keys.isShiftPressed,
      toggleModifierHeld: _isMac ? keys.isMetaPressed : keys.isControlPressed,
    );
    final checked = ref.read(selectedTorrentHashesProvider.notifier);

    switch (intent) {
      case TransfersClick.open:
        _anchorHash = torrent.hash;
        _openDetails(torrent);
      case TransfersClick.toggle:
        if (!wasSelecting) _includeOpenTransfer(ordered);
        checked.toggle(torrent.hash);
        _anchorHash = torrent.hash;
      case TransfersClick.extend:
        if (!wasSelecting) _includeOpenTransfer(ordered);
        checked.addAll(transfersRange(ordered, _anchorHash, torrent.hash));
        _anchorHash ??= torrent.hash;
    }
  }

  /// Starting a multi-selection with a modifier click keeps the transfer
  /// already highlighted in the details pane, the way a file manager does.
  void _includeOpenTransfer(List<String> ordered) {
    if (!widget.inSplitView) return;
    final open = ref.read(selectedTorrentHashProvider);
    if (open == null || !ordered.contains(open)) return;
    ref.read(selectedTorrentHashesProvider.notifier).addAll([open]);
    _anchorHash ??= open;
  }

  /// Long press, or the menu's Select: enter selection mode with this row.
  void _toggleChecked(String hash) {
    ref.read(selectionModeProvider.notifier).enable();
    ref.read(selectedTorrentHashesProvider.notifier).toggle(hash);
    _anchorHash = hash;
  }

  void _checkAll(List<Torrent> visible) {
    if (visible.isEmpty) return;
    ref.read(selectionModeProvider.notifier).enable();
    ref
        .read(selectedTorrentHashesProvider.notifier)
        .addAll(visible.map((torrent) => torrent.hash));
  }

  void _exitSelection() {
    ref.read(selectedTorrentHashesProvider.notifier).clear();
    ref.read(selectionModeProvider.notifier).disable();
  }

  void _openDetails(Torrent torrent) {
    ref.read(selectedTorrentHashProvider.notifier).set(torrent.hash);
    // Beside the list the details pane follows the selection; on a narrow
    // window they get their own page.
    if (widget.inSplitView) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TorrentDetailsScreen(torrentHash: torrent.hash),
        ),
      ),
    );
  }

  // ── Actions on one transfer ──────────────────────────────────────────

  Future<bool> _pause(Torrent torrent) => runTransferAction(
    context,
    action: TransferAction.pause,
    call: () =>
        ref.read(torrentListProvider.notifier).pauseTorrent(torrent.hash),
    successMessage: 'Paused “${torrent.name}”',
  );

  Future<bool> _resume(Torrent torrent) => runTransferAction(
    context,
    action: TransferAction.resume,
    call: () =>
        ref.read(torrentListProvider.notifier).resumeTorrent(torrent.hash),
    successMessage: 'Resumed “${torrent.name}”',
  );

  Future<bool> _delete(Torrent torrent) => confirmAndDeleteTransfers(
    context,
    ref,
    hashes: [torrent.hash],
    name: torrent.name,
  );

  // ── Actions on the selection ─────────────────────────────────────────

  Future<void> _pauseChecked(Set<String> hashes) async {
    if (hashes.isEmpty) return;
    final notifier = ref.read(torrentListProvider.notifier);
    final ok = await runTransferAction(
      context,
      action: TransferAction.pause,
      call: () => notifier.pauseTorrents(hashes.toList()),
      count: hashes.length,
    );
    if (ok && mounted) _exitSelection();
  }

  Future<void> _resumeChecked(Set<String> hashes) async {
    if (hashes.isEmpty) return;
    final notifier = ref.read(torrentListProvider.notifier);
    final ok = await runTransferAction(
      context,
      action: TransferAction.resume,
      call: () => notifier.resumeTorrents(hashes.toList()),
      count: hashes.length,
    );
    if (ok && mounted) _exitSelection();
  }

  Future<void> _deleteChecked(Set<String> hashes) async {
    if (hashes.isEmpty) return;
    final deleted = await confirmAndDeleteTransfers(
      context,
      ref,
      hashes: hashes.toList(),
    );
    if (deleted && mounted) _exitSelection();
  }
}

/// Status filter chips and the name filter.
class _FilterRow extends ConsumerWidget {
  const _FilterRow({
    required this.torrents,
    required this.searchController,
    required this.searchFocus,
    required this.compact,
  });

  final List<Torrent> torrents;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentFilterProvider);
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: TransferColumn.inset(compact: compact),
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
                      selected: filter == current,
                      count: _countFor(filter),
                      dotColor: _dotFor(filter),
                      onTap: () =>
                          ref.read(currentFilterProvider.notifier).set(filter),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          BrowseSearchPill(
            controller: searchController,
            focusNode: searchFocus,
            hint: 'Filter by name…',
            width: compact ? 180 : 220,
            onChanged: (value) =>
                ref.read(torrentSearchQueryProvider.notifier).set(value),
          ),
        ],
      ),
    );
  }

  /// The chip's dot matches the row dot for the same state.
  static Color? _dotFor(TorrentFilter filter) => switch (filter) {
    TorrentFilter.downloading => AppColors.downloading,
    TorrentFilter.seeding => AppColors.seeding,
    TorrentFilter.completed => AppColors.ok,
    TorrentFilter.paused => AppColors.paused,
    TorrentFilter.errored => AppColors.errorState,
    TorrentFilter.active || TorrentFilter.inactive || TorrentFilter.all => null,
  };

  int _countFor(TorrentFilter filter) => switch (filter) {
    TorrentFilter.all => torrents.length,
    TorrentFilter.downloading => torrents.where((t) => t.isDownloading).length,
    TorrentFilter.seeding => torrents.where((t) => t.isSeeding).length,
    TorrentFilter.completed => torrents.where((t) => t.isCompleted).length,
    TorrentFilter.paused => torrents.where((t) => t.isPaused).length,
    TorrentFilter.active => torrents.where((t) => t.isActive).length,
    TorrentFilter.inactive => torrents.where((t) => !t.isActive).length,
    TorrentFilter.errored => torrents.where((t) => t.hasError).length,
  };
}

/// Nothing to list: no transfers at all, none matching the search, or none
/// in the chosen filter — three different situations with three different
/// ways out. (A filter that matched nothing used to say "No torrents yet".)
class _EmptyTransfers extends ConsumerWidget {
  const _EmptyTransfers({
    required this.searchQuery,
    required this.hasTransfers,
  });

  final String searchQuery;
  final bool hasTransfers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (searchQuery.isNotEmpty) {
      return EmptyState.noResults(
        title: 'No transfers match “$searchQuery”',
        subtitle: 'Try a different name, or clear the search.',
        action: EditorialButton(
          label: 'Clear search',
          icon: Icons.close_rounded,
          onPressed: () =>
              ref.read(torrentSearchQueryProvider.notifier).clear(),
        ),
      );
    }
    if (hasTransfers) {
      final filter = ref.watch(currentFilterProvider);
      return EmptyState.noResults(
        title: 'Nothing under “${filter.label}”',
        subtitle: 'None of your transfers match this filter right now.',
        action: EditorialButton(
          label: 'Show all',
          icon: Icons.filter_list_off_rounded,
          onPressed: () =>
              ref.read(currentFilterProvider.notifier).set(TorrentFilter.all),
        ),
      );
    }
    return EmptyState.noData(
      icon: Icons.download_outlined,
      title: 'No transfers yet',
      subtitle: 'Find a show or movie, then choose Download or Stream.',
      action: EditorialButton(
        label: 'Browse shows',
        icon: Icons.live_tv_rounded,
        kind: EditorialButtonKind.accent,
        onPressed: () =>
            ref.read(currentTabIndexProvider.notifier).show(AppTab.shows),
      ),
    );
  }
}

/// Aggregate `↓ X MB/s · ↑ Y MB/s` pill rendered in the TopBar
/// actions row on the Transfers tab. Matches the design's status
/// widget on `screen-transfers.jsx`.
class TransfersSpeedPill extends StatelessWidget {
  const TransfersSpeedPill({
    super.key,
    required this.totalDl,
    required this.totalUl,
  });

  final int totalDl;
  final int totalUl;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          'Downloading at ${Formatters.formatSpeed(totalDl)}, '
          'uploading at ${Formatters.formatSpeed(totalUl)}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.bgSurface,
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SpeedReading(
                tone: AppColors.downloading,
                arrow: '↓',
                bytesPerSecond: totalDl,
              ),
              Container(
                width: 1,
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                color: AppColors.line,
              ),
              _SpeedReading(
                tone: AppColors.seeding,
                arrow: '↑',
                bytesPerSecond: totalUl,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedReading extends StatelessWidget {
  const _SpeedReading({
    required this.tone,
    required this.arrow,
    required this.bytesPerSecond,
  });

  final Color tone;
  final String arrow;
  final int bytesPerSecond;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: tone,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: tone.withAlpha(AppOpacity.semi), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          arrow,
          style: AppType.mono(size: AppType.sizeSmall, color: AppColors.fg2),
        ),
        const SizedBox(width: AppSpacing.xxs),
        Text(
          Formatters.formatSpeed(bytesPerSecond),
          style: AppType.mono(
            size: AppType.sizeCaption,
            color: AppColors.fg,
            weight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Count, select-all and the bulk actions while picking several transfers.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.selectedCount,
    required this.totalCount,
    required this.inset,
    required this.onSelectAll,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
    required this.onExit,
  });

  final int selectedCount;
  final int totalCount;
  final double inset;
  final VoidCallback onSelectAll;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDelete;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final hasSelection = selectedCount > 0;
    final canSelectAll = totalCount > 0 && selectedCount < totalCount;

    return Container(
      margin: EdgeInsets.fromLTRB(inset, AppSpacing.sm, inset, AppSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.lineStrong),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.checklist_rounded,
            size: AppIconSize.sm,
            color: AppColors.accent,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '$selectedCount selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.ui(
                size: AppType.sizeBody,
                color: AppColors.fg,
                weight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Select all',
            onPressed: canSelectAll ? onSelectAll : null,
            color: AppColors.fg1,
            icon: const Icon(Icons.select_all_rounded),
          ),
          IconButton(
            tooltip: 'Pause',
            onPressed: hasSelection ? onPause : null,
            color: AppColors.fg1,
            icon: const Icon(Icons.pause_rounded),
          ),
          IconButton(
            tooltip: 'Resume',
            onPressed: hasSelection ? onResume : null,
            color: AppColors.fg1,
            icon: const Icon(Icons.play_arrow_rounded),
          ),
          IconButton(
            tooltip: 'Delete…',
            onPressed: hasSelection ? onDelete : null,
            color: AppColors.err,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          IconButton(
            tooltip: 'Exit selection (Esc)',
            onPressed: onExit,
            color: AppColors.fg1,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
