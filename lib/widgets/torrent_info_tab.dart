import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/torrent.dart';
import '../utils/feedback_utils.dart';
import '../utils/formatters.dart';
import 'editorial/editorial.dart';
import 'transfers/engine_reporting.dart';

/// One labelled value on the Info tab.
typedef InfoField = ({String label, String value, bool copyable});

InfoField _field(String label, String value, {bool copyable = false}) =>
    (label: label, value: value, copyable: copyable);

/// The Info tab's sections, holding only what the engine actually reported.
///
/// A zero here means "not reported", not "zero": the built-in engine keeps
/// no add or activity times, and neither engine puts piece size or pieces
/// downloaded on its torrent list. Printing them gave "Added on: Unknown",
/// "Last activity: Never" on an active download and "Pieces have: 0" at
/// 100%. Such rows are left out, and a section with nothing left goes too.
List<({String title, List<InfoField> fields})> torrentInfoSections(
  Torrent torrent,
  EngineReporting reporting,
) {
  final t = torrent;
  final general = [
    _field('Name', t.name),
    _field('Hash', t.hash, copyable: true),
    if (t.savePath.isNotEmpty) _field('Save path', t.savePath, copyable: true),
    if (t.contentPath.isNotEmpty && t.contentPath != t.savePath)
      _field('Content path', t.contentPath, copyable: true),
    if (t.category.isNotEmpty) _field('Category', t.category),
    if (t.tags.isNotEmpty) _field('Tags', t.tags),
  ];
  final transfer = [
    _field('Total size', Formatters.formatBytes(t.size)),
    _field('Downloaded', Formatters.formatBytes(t.downloaded)),
    _field('Uploaded', Formatters.formatBytes(t.uploaded)),
    _field('Remaining', Formatters.formatBytes(t.amountLeft)),
    _field('Share ratio', Formatters.formatRatio(t.ratio)),
  ];
  final dates = [
    if (t.addedOn > 0) _field('Added on', Formatters.formatDate(t.addedOn)),
    if (t.completionOn > 0)
      _field('Completed on', Formatters.formatDate(t.completionOn)),
    if (t.lastActivity > 0)
      _field('Last activity', Formatters.formatRelativeTime(t.lastActivity)),
    if (t.seenComplete > 0)
      _field('Last seen complete', Formatters.formatDate(t.seenComplete)),
  ];
  final pieces = [
    if (t.pieceSize > 0)
      _field('Piece size', Formatters.formatBytes(t.pieceSize)),
    if (t.piecesNum > 0)
      _field(
        'Pieces',
        t.piecesHave > 0
            ? '${t.piecesHave} of ${t.piecesNum} downloaded'
            : '${t.piecesNum}',
      ),
  ];
  final swarm = [
    if (reporting.seedsAndPeersSplit) ...[
      _field('Seeds', _connectedOf(t.numSeeds, t.numComplete)),
      _field('Peers', _connectedOf(t.numLeeches, t.numIncomplete)),
    ] else ...[
      // The built-in engine counts connected peers without telling seeds
      // from leechers, and reports how many it has seen in total.
      _field('Connected peers', '${t.numSeeds}'),
      if (t.numComplete > 0) _field('Peers seen', '${t.numComplete}'),
    ],
    if (t.tracker.isNotEmpty) _field('Tracker', t.tracker, copyable: true),
  ];

  return [
    (title: 'General', fields: general),
    (title: 'Transfer', fields: transfer),
    if (dates.isNotEmpty) (title: 'Dates', fields: dates),
    if (pieces.isNotEmpty) (title: 'Pieces', fields: pieces),
    (title: 'Swarm', fields: swarm),
  ];
}

String _connectedOf(int connected, int inSwarm) =>
    inSwarm > 0 ? '$connected connected · $inSwarm in swarm' : '$connected';

/// A torrent's properties, for the curious: paths, hash, totals, dates.
class TorrentInfoTab extends ConsumerWidget {
  const TorrentInfoTab({super.key, required this.torrent});

  final Torrent torrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = torrentInfoSections(
      torrent,
      ref.watch(engineReportingProvider),
    );
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      children: [
        for (final section in sections)
          _InfoSection(title: section.title, fields: section.fields),
      ],
    );
  }
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.title, required this.fields});

  final String title;
  final List<InfoField> fields;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: MonoLabel(title, color: AppColors.fg2),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final field in fields) _InfoRow(field: field),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.field});

  final InfoField field;

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: field.value));
    AppSnackBar.showOn(messenger, message: '${field.label} copied');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              field.label,
              style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg2),
            ),
          ),
          Expanded(
            child: SelectableText(
              field.value,
              style: AppType.ui(size: AppType.sizeBody, color: AppColors.fg1),
            ),
          ),
          if (field.copyable)
            IconButton(
              tooltip: 'Copy ${field.label.toLowerCase()}',
              onPressed: () => unawaited(_copy(context)),
              color: AppColors.fg2,
              iconSize: AppIconSize.sm,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy_rounded),
            ),
        ],
      ),
    );
  }
}
