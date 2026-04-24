import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_tokens.dart';
import '../models/torrent.dart';
import '../utils/formatters.dart';

/// Tab widget for displaying torrent info/properties
class TorrentInfoTab extends StatelessWidget {
  final Torrent torrent;

  const TorrentInfoTab({super.key, required this.torrent});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _buildSection(context, 'General', [
          _InfoRow(label: 'Name', value: torrent.name),
          _InfoRow(label: 'Hash', value: torrent.hash, copyable: true),
          _InfoRow(label: 'Save Path', value: torrent.savePath),
          _InfoRow(label: 'Content Path', value: torrent.contentPath),
          if (torrent.category.isNotEmpty)
            _InfoRow(label: 'Category', value: torrent.category),
          if (torrent.tags.isNotEmpty)
            _InfoRow(label: 'Tags', value: torrent.tags),
        ]),
        const SizedBox(height: AppSpacing.lg),
        _buildSection(context, 'Transfer', [
          _InfoRow(
            label: 'Total Size',
            value: Formatters.formatBytes(torrent.size),
          ),
          _InfoRow(
            label: 'Downloaded',
            value: Formatters.formatBytes(torrent.downloaded),
          ),
          _InfoRow(
            label: 'Uploaded',
            value: Formatters.formatBytes(torrent.uploaded),
          ),
          _InfoRow(
            label: 'Remaining',
            value: Formatters.formatBytes(torrent.amountLeft),
          ),
          _InfoRow(
            label: 'Share Ratio',
            value: Formatters.formatRatio(torrent.ratio),
          ),
        ]),
        const SizedBox(height: AppSpacing.lg),
        _buildSection(context, 'Dates', [
          _InfoRow(
            label: 'Added On',
            value: Formatters.formatDate(torrent.addedOn),
          ),
          if (torrent.completionOn > 0)
            _InfoRow(
              label: 'Completed On',
              value: Formatters.formatDate(torrent.completionOn),
            ),
          _InfoRow(
            label: 'Last Activity',
            value: torrent.lastActivity > 0
                ? Formatters.formatRelativeTime(torrent.lastActivity)
                : 'Never',
          ),
          if (torrent.seenComplete > 0)
            _InfoRow(
              label: 'Last Seen Complete',
              value: Formatters.formatDate(torrent.seenComplete),
            ),
        ]),
        const SizedBox(height: 16),
        _buildSection(context, 'Pieces', [
          _InfoRow(
            label: 'Piece Size',
            value: Formatters.formatBytes(torrent.pieceSize),
          ),
          _InfoRow(label: 'Total Pieces', value: '${torrent.piecesNum}'),
          _InfoRow(label: 'Pieces Have', value: '${torrent.piecesHave}'),
        ]),
        const SizedBox(height: 16),
        _buildSection(context, 'Connections', [
          _InfoRow(
            label: 'Seeds',
            value: '${torrent.numSeeds} (${torrent.numComplete} total)',
          ),
          _InfoRow(
            label: 'Peers',
            value: '${torrent.numLeeches} (${torrent.numIncomplete} total)',
          ),
          if (torrent.tracker.isNotEmpty)
            _InfoRow(label: 'Tracker', value: torrent.tracker),
        ]),
      ],
    );
  }

  Widget _buildSection(
    BuildContext context,
    String title,
    List<Widget> children,
  ) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool copyable;

  const _InfoRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withAlpha(153),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
          if (copyable)
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
              tooltip: 'Copy',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}
