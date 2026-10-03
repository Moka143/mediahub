import '../../models/torrent.dart';
import '../../utils/constants.dart';
import '../../utils/formatters.dart';

/// Whether data is actually moving in for [torrent] right now.
///
/// Narrower than [Torrent.isDownloading], which also counts torrents that are
/// queued, checking, fetching metadata or stalled with no peers. Those are
/// waiting, not working, and a stalled torrent can sit like that for hours —
/// anything animated on their behalf would keep the app from ever reaching
/// an idle frame for nothing.
bool isTransferring(Torrent torrent) =>
    torrent.state == TorrentState.downloading ||
    torrent.state == TorrentState.forcedDL;

/// The ETA column and pill: a duration while something is still coming in,
/// a dash when there is nothing left to wait for.
///
/// [Formatters.formatDuration] already renders the engines' "unknown"
/// sentinel as ∞; this only adds that a finished or paused torrent has no ETA
/// at all (qBittorrent reports the sentinel for those too, and "∞" next to a
/// completed download reads as "never").
String transferEtaLabel(Torrent torrent) {
  if (torrent.isCompleted || torrent.isPaused || torrent.hasError) return '—';
  return Formatters.formatDuration(torrent.eta);
}
