import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_tokens.dart';
import '../models/peer.dart';
import '../providers/torrent_provider.dart';
import '../utils/formatters.dart';
import 'common/empty_state.dart';
import 'common/loading_state.dart';

/// Tab widget for displaying torrent peers
class TorrentPeersTab extends ConsumerWidget {
  final String torrentHash;

  const TorrentPeersTab({super.key, required this.torrentHash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peersAsync = ref.watch(torrentPeersProvider(torrentHash));

    return peersAsync.when(
      data: (peers) => _buildPeersList(context, ref, peers),
      loading: () => const LoadingIndicator(message: 'Loading peers...'),
      error: (error, stack) => EmptyState.error(
        message: error.toString(),
        onRetry: () => ref.invalidate(torrentPeersProvider(torrentHash)),
      ),
    );
  }

  Widget _buildPeersList(
    BuildContext context,
    WidgetRef ref,
    List<Peer> peers,
  ) {
    if (peers.isEmpty) {
      return EmptyState.noData(
        icon: Icons.people_outline,
        title: 'No peers connected',
      );
    }

    final theme = Theme.of(context);

    return Column(
      children: [
        // Header
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          color: theme.colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('IP Address', style: theme.textTheme.labelSmall),
              ),
              Expanded(
                flex: 2,
                child: Text('Client', style: theme.textTheme.labelSmall),
              ),
              Expanded(
                child: Text('Progress', style: theme.textTheme.labelSmall),
              ),
              Expanded(child: Text('Down', style: theme.textTheme.labelSmall)),
              Expanded(child: Text('Up', style: theme.textTheme.labelSmall)),
            ],
          ),
        ),
        // Peer list
        Expanded(
          child: ListView.builder(
            itemCount: peers.length,
            itemBuilder: (context, index) {
              final peer = peers[index];
              return _PeerListItem(peer: peer);
            },
          ),
        ),
        // Summary
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          color: theme.colorScheme.surfaceContainerHighest,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${peers.length} peers connected',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PeerListItem extends StatelessWidget {
  final Peer peer;

  const _PeerListItem({required this.peer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodySmall;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withAlpha(25)),
        ),
      ),
      child: Row(
        children: [
          // IP Address
          Expanded(
            flex: 3,
            child: Row(
              children: [
                if (peer.countryCode.isNotEmpty) ...[
                  Text(
                    _countryCodeToEmoji(peer.countryCode),
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    peer.address,
                    style: textStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Client
          Expanded(
            flex: 2,
            child: Text(
              peer.client,
              style: textStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Progress
          Expanded(
            child: Text(
              Formatters.formatProgress(peer.progress),
              style: textStyle,
            ),
          ),
          // Download speed
          Expanded(
            child: Text(
              peer.dlSpeed > 0 ? Formatters.formatSpeed(peer.dlSpeed) : '-',
              style: textStyle?.copyWith(
                color: peer.dlSpeed > 0 ? Colors.blue : null,
              ),
            ),
          ),
          // Upload speed
          Expanded(
            child: Text(
              peer.upSpeed > 0 ? Formatters.formatSpeed(peer.upSpeed) : '-',
              style: textStyle?.copyWith(
                color: peer.upSpeed > 0 ? Colors.green : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _countryCodeToEmoji(String countryCode) {
    if (countryCode.length != 2) return '';
    final firstLetter = countryCode.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final secondLetter = countryCode.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCode(firstLetter) + String.fromCharCode(secondLetter);
  }
}
