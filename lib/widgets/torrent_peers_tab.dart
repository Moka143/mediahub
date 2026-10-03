import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/app_colors.dart';
import '../design/app_tokens.dart';
import '../design/app_typography.dart';
import '../models/peer.dart';
import '../providers/torrent_provider.dart';
import '../utils/formatters.dart';
import 'common/empty_state.dart';
import 'common/loading_state.dart';
import 'transfers/engine_reporting.dart';

/// The flag emoji for a two-letter country code, or '' when there is none.
///
/// Regional-indicator symbols are offsets from 'A', so the code has to be
/// upper case — qBittorrent sends lower case ("us"), which rendered as two
/// stray symbols. Anything that is not two letters A–Z gets no flag.
String countryFlag(String code) {
  final upper = code.trim().toUpperCase();
  if (upper.length != 2) return '';
  final first = upper.codeUnitAt(0);
  final second = upper.codeUnitAt(1);
  bool isLetter(int unit) => unit >= 0x41 && unit <= 0x5A;
  if (!isLetter(first) || !isLetter(second)) return '';
  const regionalA = 0x1F1E6;
  return String.fromCharCodes([
    regionalA + first - 0x41,
    regionalA + second - 0x41,
  ]);
}

/// "live" → "Live", "not_needed" → "Not needed": the built-in engine's
/// connection states, readable.
String _peerState(String raw) {
  final words = raw.trim().replaceAll('_', ' ');
  if (words.isEmpty) return '—';
  return words[0].toUpperCase() + words.substring(1);
}

/// The peers a torrent is connected to.
///
/// qBittorrent reports each peer's client, progress and live rates. The
/// built-in engine reports none of those — they used to render as "0.0%"
/// and "-" on every row — but it does count the bytes exchanged with each
/// peer, so that is what its table shows.
class TorrentPeersTab extends ConsumerWidget {
  const TorrentPeersTab({super.key, required this.torrentHash});

  final String torrentHash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peersAsync = ref.watch(torrentPeersProvider(torrentHash));
    final reporting = ref.watch(engineReportingProvider);

    return peersAsync.when(
      data: (peers) => peers.isEmpty
          ? EmptyState.noData(
              icon: Icons.people_outline_rounded,
              title: 'No peers connected',
              subtitle: 'Peers show up here as the engine finds them.',
            )
          : _PeerTable(peers: peers, rates: reporting.peerRates),
      loading: () => const LoadingIndicator(message: 'Loading peers…'),
      error: (_, _) => EmptyState.error(
        title: "Couldn't load the peers",
        message: "The torrent engine didn't answer.",
        onRetry: () => ref.invalidate(torrentPeersProvider(torrentHash)),
      ),
    );
  }
}

typedef _Column = ({String label, int flex});

class _PeerTable extends StatelessWidget {
  const _PeerTable({required this.peers, required this.rates});

  final List<Peer> peers;

  /// Client, progress and speeds are real (qBittorrent). Otherwise the
  /// table shows connection state and byte counters.
  final bool rates;

  List<_Column> get _columns => rates
      ? const [
          (label: 'Address', flex: 3),
          (label: 'Client', flex: 2),
          (label: 'Progress', flex: 1),
          (label: 'Down', flex: 1),
          (label: 'Up', flex: 1),
        ]
      : const [
          (label: 'Address', flex: 3),
          (label: 'State', flex: 2),
          (label: 'Received', flex: 1),
          (label: 'Sent', flex: 1),
        ];

  @override
  Widget build(BuildContext context) {
    final columns = _columns;
    return Column(
      children: [
        _TableLine(
          header: true,
          cells: [
            for (final column in columns)
              (
                flex: column.flex,
                child: Text(
                  column.label.toUpperCase(),
                  style: AppType.mono(
                    size: AppType.sizeLabel,
                    color: AppColors.fg2,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            itemCount: peers.length,
            itemBuilder: (context, index) {
              final peer = peers[index];
              final values = rates ? _rateCells(peer) : _counterCells(peer);
              return _TableLine(
                cells: [
                  for (var i = 0; i < columns.length; i++)
                    (flex: columns[i].flex, child: values[i]),
                ],
              );
            },
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.line)),
          ),
          child: Text(
            '${peers.length} ${peers.length == 1 ? 'peer' : 'peers'} '
            'connected',
            textAlign: TextAlign.center,
            style: AppType.caption(color: AppColors.fg2),
          ),
        ),
      ],
    );
  }

  List<Widget> _rateCells(Peer peer) => [
    _AddressCell(peer: peer),
    _cellText(peer.client.isEmpty ? '—' : peer.client),
    _cellText(Formatters.formatProgress(peer.progress), mono: true),
    _speed(peer.dlSpeed, AppColors.downloading),
    _speed(peer.upSpeed, AppColors.seeding),
  ];

  List<Widget> _counterCells(Peer peer) => [
    _AddressCell(peer: peer),
    _cellText(_peerState(peer.connection)),
    _cellText(Formatters.formatBytes(peer.downloaded), mono: true),
    _cellText(Formatters.formatBytes(peer.uploaded), mono: true),
  ];

  Widget _speed(int bytesPerSecond, Color tone) {
    final moving = bytesPerSecond > 0;
    return _cellText(
      moving ? Formatters.formatSpeed(bytesPerSecond) : '—',
      mono: true,
      color: moving ? tone : AppColors.fg2,
    );
  }
}

Widget _cellText(String text, {bool mono = false, Color? color}) {
  final tone = color ?? AppColors.fg1;
  return Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: mono
        ? AppType.mono(size: AppType.sizeSmall, color: tone)
        : AppType.caption(color: tone),
  );
}

class _AddressCell extends StatelessWidget {
  const _AddressCell({required this.peer});

  final Peer peer;

  @override
  Widget build(BuildContext context) {
    final flag = countryFlag(peer.countryCode);
    return Row(
      children: [
        if (flag.isNotEmpty) ...[
          Tooltip(
            message: peer.country.isEmpty ? peer.countryCode : peer.country,
            child: Text(
              flag,
              style: AppType.ui(size: AppType.sizeLead, height: 1.5),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(child: _cellText(peer.address, mono: true)),
      ],
    );
  }
}

class _TableLine extends StatelessWidget {
  const _TableLine({required this.cells, this.header = false});

  final List<({int flex, Widget child})> cells;
  final bool header;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: header ? AppColors.bgSurface : null,
        border: const Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(flex: cells[i].flex, child: cells[i].child),
          ],
        ],
      ),
    );
  }
}
