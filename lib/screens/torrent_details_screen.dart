import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../design/torrent_tone.dart';
import '../models/torrent.dart';
import '../models/torrent_action_result.dart';
import '../providers/connection_provider.dart';
import '../providers/torrent_provider.dart';
import '../utils/formatters.dart';
import '../widgets/common/back_shortcuts.dart';
import '../widgets/common/empty_state.dart';
import '../widgets/common/mediahub_topbar.dart';
import '../widgets/connection_status_widget.dart';
import '../widgets/editorial/editorial.dart';
import '../widgets/torrent_files_tab.dart';
import '../widgets/torrent_info_tab.dart';
import '../widgets/torrent_peers_tab.dart';
import '../widgets/torrent_trackers_tab.dart';
import '../widgets/transfers/engine_reporting.dart';
import '../widgets/transfers/transfer_actions.dart';
import '../widgets/transfers/transfer_labels.dart';
import 'settings_screen.dart';

/// A transfer's details: live stats, the Files / Peers / Trackers / Info
/// tabs, and what can be done to it.
///
/// Two homes. [embedded], it is the pane beside the Transfers list and
/// follows the list's selection; otherwise it is a page of its own, pushed on
/// narrow windows.
class TorrentDetailsScreen extends ConsumerWidget {
  const TorrentDetailsScreen({
    super.key,
    required this.torrentHash,
    this.embedded = false,
  });

  final String torrentHash;

  /// Beside the list, without page chrome. Closing it means clearing the
  /// selection — never popping, since there is no page to pop.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // This screen's own hash, looked up in the live list — not the list's
    // selection, which a pushed page does not own. `Torrent` compares by
    // value, so this rebuilds when this transfer changes and not when
    // another one does.
    final torrent = ref.watch(
      torrentListProvider.select(
        (state) =>
            state.torrents.firstWhereOrNull((t) => t.hash == torrentHash),
      ),
    );

    if (embedded) {
      if (torrent == null) {
        return _TransferGone(
          actionLabel: 'Close',
          onAction: () =>
              ref.read(selectedTorrentHashProvider.notifier).clear(),
        );
      }
      return Column(
        children: [
          _DetailsHeader(
            torrent: torrent,
            compact: true,
            onRefresh: () => refreshTransferDetails(ref, torrentHash),
          ),
          Expanded(child: _DetailTabs(torrent: torrent, compact: true)),
          _DetailActions(torrent: torrent, embedded: true),
        ],
      );
    }

    final connected = ref.watch(
      connectionProvider.select((c) => c.isConnected),
    );
    final Widget body;
    if (!connected) {
      body = EngineOfflineState(onOpenSettings: () => _openSettings(context));
    } else if (torrent == null) {
      body = _TransferGone(
        actionLabel: 'Back to Transfers',
        onAction: () => unawaited(Navigator.of(context).maybePop()),
      );
    } else {
      body = Column(
        children: [
          _DetailsHeader(torrent: torrent, compact: false),
          Expanded(child: _DetailTabs(torrent: torrent, compact: false)),
          _DetailActions(torrent: torrent, embedded: false),
        ],
      );
    }

    return BackShortcuts(
      child: Scaffold(
        appBar: MediaHubTopBar(
          title: 'Transfer details',
          leading: MediaHubIconButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Back',
            onPressed: () => unawaited(Navigator.of(context).maybePop()),
          ),
          actions: [
            if (connected && torrent != null)
              MediaHubIconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Refresh details',
                onPressed: () => refreshTransferDetails(ref, torrentHash),
              ),
            MediaHubIconButton(
              icon: Icons.settings_outlined,
              tooltip: 'Settings',
              onPressed: () => _openSettings(context),
            ),
          ],
        ),
        body: body,
      ),
    );
  }
}

/// Re-fetch everything the details show for [hash] now, rather than at the
/// next poll.
void refreshTransferDetails(WidgetRef ref, String hash) {
  ref
    ..invalidate(torrentFilesProvider(hash))
    ..invalidate(torrentPeersProvider(hash))
    ..invalidate(torrentTrackersProvider(hash));
  unawaited(ref.read(torrentListProvider.notifier).refresh());
}

void _openSettings(BuildContext context) => unawaited(
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
);

/// Status, name, progress and the live numbers.
class _DetailsHeader extends ConsumerWidget {
  const _DetailsHeader({
    required this.torrent,
    required this.compact,
    this.onRefresh,
  });

  final Torrent torrent;
  final bool compact;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reporting = ref.watch(engineReportingProvider);
    final tone = torrentStateTone(torrent);
    final done = (torrent.size - torrent.amountLeft).clamp(0, torrent.size);
    final onRefresh = this.onRefresh;

    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
            )
          : const EdgeInsets.fromLTRB(
              AppSpacing.xxl,
              AppSpacing.xl,
              AppSpacing.xxl,
              AppSpacing.lg,
            ),
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              EditorialBadge(torrent.statusText, tone: tone),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  torrent.name,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.mono(
                    size: compact ? 13 : 15,
                    color: AppColors.fg,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                Formatters.formatProgress(torrent.progress),
                style: AppType.mono(
                  size: compact ? 16 : 22,
                  color: tone,
                  weight: FontWeight.w700,
                ),
              ),
              if (onRefresh != null) ...[
                const SizedBox(width: AppSpacing.sm),
                MediaHubIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Refresh details',
                  onPressed: onRefresh,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          EditorialProgress(
            value: torrent.progress,
            color: tone,
            height: compact ? 5 : 8,
            glow: isTransferring(torrent),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _StatPill(
                icon: Icons.download_rounded,
                label: 'Down',
                value: Formatters.formatSpeed(torrent.dlspeed),
                tone: AppColors.downloading,
              ),
              _StatPill(
                icon: Icons.upload_rounded,
                label: 'Up',
                value: Formatters.formatSpeed(torrent.upspeed),
                tone: AppColors.seeding,
              ),
              _StatPill(
                icon: Icons.timer_outlined,
                label: 'ETA',
                value: transferEtaLabel(torrent),
              ),
              _StatPill(
                icon: Icons.storage_rounded,
                label: 'Size',
                value:
                    '${Formatters.formatBytes(done)} of '
                    '${Formatters.formatBytes(torrent.size)}',
              ),
              _StatPill(
                icon: Icons.people_alt_outlined,
                label: 'Connected',
                value: swarmLabel(torrent, reporting),
              ),
              _StatPill(
                icon: Icons.swap_vert_rounded,
                label: 'Ratio',
                value: Formatters.formatRatio(torrent.ratio),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.icon,
    required this.label,
    required this.value,
    this.tone = AppColors.fg2,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.bgSurface,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: AppIconSize.xs, color: tone),
              const SizedBox(width: AppSpacing.xs + AppSpacing.xxs),
              Text(
                label.toUpperCase(),
                style: AppType.mono(
                  size: AppType.sizeLabel,
                  color: AppColors.fg2,
                ),
              ),
              const SizedBox(width: AppSpacing.xs + AppSpacing.xxs),
              Text(
                value,
                style: AppType.mono(
                  size: AppType.sizeCaption,
                  color: AppColors.fg,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tabs this engine can fill.
///
/// qBittorrent answers all four. An engine without a tracker table
/// (`EngineCapabilities.trackers`) drops that tab rather than rendering a
/// permanently empty one — and with it goes the polling behind it.
class _DetailTabs extends ConsumerWidget {
  const _DetailTabs({required this.torrent, required this.compact});

  final Torrent torrent;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capabilities = ref.watch(
      torrentEngineProvider.select((engine) => engine.capabilities),
    );
    final hash = torrent.hash;

    // Keyed by hash: beside the list this screen is reused as the selection
    // moves, and a Files tab carrying one torrent's ticked files over to the
    // next would apply a priority change to the wrong files.
    final tabs = <({String label, IconData icon, Widget view})>[
      (
        label: 'Files',
        icon: Icons.folder_outlined,
        view: TorrentFilesTab(key: ValueKey('files:$hash'), torrentHash: hash),
      ),
      if (capabilities.peers)
        (
          label: 'Peers',
          icon: Icons.people_outline_rounded,
          view: TorrentPeersTab(
            key: ValueKey('peers:$hash'),
            torrentHash: hash,
          ),
        ),
      if (capabilities.trackers)
        (
          label: 'Trackers',
          icon: Icons.dns_outlined,
          view: TorrentTrackersTab(
            key: ValueKey('trackers:$hash'),
            torrentHash: hash,
          ),
        ),
      (
        label: 'Info',
        icon: Icons.info_outline_rounded,
        view: TorrentInfoTab(torrent: torrent),
      ),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.line)),
            ),
            child: TabBar(
              tabs: [
                for (final tab in tabs)
                  Tab(
                    height: compact ? 40 : 46,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(tab.icon, size: AppIconSize.sm),
                        const SizedBox(width: AppSpacing.xs + AppSpacing.xxs),
                        Text(tab.label),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(children: [for (final tab in tabs) tab.view]),
          ),
        ],
      ),
    );
  }
}

/// Pause or resume, recheck, reannounce, delete — each reporting a failure
/// the way the list rows do.
///
/// Recheck and reannounce are hidden for an engine that does not offer them
/// (`EngineCapabilities.maintenanceActions`) rather than left to fail — a
/// button whose only outcome is an error message is worse than no button.
class _DetailActions extends ConsumerWidget {
  const _DetailActions({required this.torrent, required this.embedded});

  final Torrent torrent;
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maintenance = ref.watch(
      torrentEngineProvider.select(
        (engine) => engine.capabilities.maintenanceActions,
      ),
    );
    final hash = torrent.hash;

    void run(
      TransferAction action,
      Future<TorrentActionResult> Function(TorrentListNotifier list) call, {
      String? successMessage,
    }) {
      final list = ref.read(torrentListProvider.notifier);
      unawaited(
        runTransferAction(
          context,
          action: action,
          call: () => call(list),
          successMessage: successMessage,
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: embedded ? AppSpacing.lg : AppSpacing.xxl,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        color: AppColors.bgPage,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          if (torrent.isPaused)
            EditorialButton(
              label: 'Resume',
              icon: Icons.play_arrow_rounded,
              onPressed: () => run(
                TransferAction.resume,
                (list) => list.resumeTorrent(hash),
              ),
            )
          else
            EditorialButton(
              label: 'Pause',
              icon: Icons.pause_rounded,
              onPressed: () =>
                  run(TransferAction.pause, (list) => list.pauseTorrent(hash)),
            ),
          if (maintenance) ...[
            Tooltip(
              message: 'Verify the downloaded data against the torrent',
              child: EditorialButton(
                label: 'Recheck',
                icon: Icons.fact_check_outlined,
                onPressed: () => run(
                  TransferAction.recheck,
                  (list) => list.recheckTorrent(hash),
                  successMessage: 'Checking the downloaded data…',
                ),
              ),
            ),
            Tooltip(
              message: 'Ask the trackers for more peers now',
              child: EditorialButton(
                label: 'Reannounce',
                icon: Icons.campaign_outlined,
                onPressed: () => run(
                  TransferAction.reannounce,
                  (list) => list.reannounceTorrent(hash),
                  successMessage: 'Asked the trackers for more peers',
                ),
              ),
            ),
          ],
          EditorialButton(
            label: 'Delete…',
            icon: Icons.delete_outline_rounded,
            kind: EditorialButtonKind.danger,
            onPressed: () => unawaited(_delete(context, ref)),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    // Everything used after the dialog is read now: deleting the selected
    // transfer can unmount this pane before the engine has even answered.
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = Navigator.of(context);
    final hash = torrent.hash;

    final deleted = await confirmAndDeleteTransfers(
      context,
      ref,
      hashes: [hash],
      name: torrent.name,
    );
    if (!deleted) return;

    if (embedded) {
      // A pane, not a page. Popping here popped the app's only route and
      // left a black window; closing the pane is what "the thing I was
      // looking at is gone" means. Only if it still shows this transfer —
      // the selection may have moved on while the engine was answering.
      if (container.read(selectedTorrentHashProvider) == hash) {
        container.read(selectedTorrentHashProvider.notifier).clear();
      }
      return;
    }
    if (context.mounted) unawaited(navigator.maybePop());
  }
}

/// The transfer this screen was showing is no longer in the engine's list.
class _TransferGone extends StatelessWidget {
  const _TransferGone({required this.actionLabel, required this.onAction});

  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return EmptyState.noData(
      icon: Icons.inbox_outlined,
      title: 'This transfer is gone',
      subtitle: "It's no longer in the engine's list.",
      action: EditorialButton(label: actionLabel, onPressed: onAction),
    );
  }
}
