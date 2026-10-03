import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/torrent.dart';
import '../../providers/connection_provider.dart';
import '../../services/torrent_engine.dart';

/// What the engine in use *reports* about a torrent, as opposed to what it
/// can *do*.
///
/// `EngineCapabilities` answers the second question; nothing there answers
/// the first. The built-in engine counts connected peers without splitting
/// them into seeds and leechers (its mapping puts the whole count in
/// `numSeeds`), and gives a peer no client name, progress or live rates —
/// only byte counters. Rendering qBittorrent's columns for it filled the
/// Peers tab with "0.0%" and "-" and labelled every connected peer a seed.
///
/// Read from the engine's own [EngineCapabilities], so a new engine
/// describes itself where it declares everything else it can and can't do.
class EngineReporting {
  const EngineReporting({
    required this.seedsAndPeersSplit,
    required this.peerRates,
  });

  /// What an engine with [capabilities] reports.
  factory EngineReporting.fromCapabilities(EngineCapabilities capabilities) =>
      EngineReporting(
        seedsAndPeersSplit: capabilities.seedsAndPeersSplit,
        peerRates: capabilities.peerDetails,
      );

  /// The built-in engine: live peers, no seed/leecher split, no per-peer
  /// rates.
  static const builtIn = EngineReporting(
    seedsAndPeersSplit: false,
    peerRates: false,
  );

  /// qBittorrent: the full peer table.
  static const full = EngineReporting(
    seedsAndPeersSplit: true,
    peerRates: true,
  );

  /// Connected peers come split into seeds (`numSeeds`) and leechers
  /// (`numLeeches`), with swarm totals in `numComplete` / `numIncomplete`.
  final bool seedsAndPeersSplit;

  /// Each peer carries a client name, its own progress and live speeds.
  /// Without them only the byte counters and connection state are real.
  final bool peerRates;
}

/// [EngineReporting] for the engine currently in use.
final engineReportingProvider = Provider<EngineReporting>((ref) {
  final split = ref.watch(
    torrentEngineProvider.select((e) => e.capabilities.seedsAndPeersSplit),
  );
  final details = ref.watch(
    torrentEngineProvider.select((e) => e.capabilities.peerDetails),
  );
  return split && details
      ? EngineReporting.full
      : split || details
      ? EngineReporting(seedsAndPeersSplit: split, peerRates: details)
      : EngineReporting.builtIn;
});

/// The one wording for who a torrent is connected to — "12 seeds · 3 peers".
///
/// Where the engine does not split seeds from leechers the count is simply
/// connected peers ("12 peers"), rather than "12 seeds · 0 peers".
String swarmLabel(Torrent torrent, EngineReporting reporting) {
  if (!reporting.seedsAndPeersSplit) {
    return _count(torrent.numSeeds, 'peer', 'peers');
  }
  return '${_count(torrent.numSeeds, 'seed', 'seeds')} · '
      '${_count(torrent.numLeeches, 'peer', 'peers')}';
}

String _count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
