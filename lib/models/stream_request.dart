import 'eztv_torrent.dart';
import 'torrentio_stream.dart';

/// Everything [StreamingService] needs to stand up a streaming session,
/// independent of which indexer the torrent came from.
///
/// Before this existed, `StreamingService` took a `TorrentioStream`
/// directly, so the binge / next-episode flow — which resolves torrents
/// through `AutoDownloadService` and gets back an `EztvTorrent` — could not
/// use it. That flow grew its own parallel implementation inside
/// `video_player_screen.dart`: its own file selection, its own buffer
/// threshold check, its own on-disk file lookup and its own
/// `LocalStreamingServer` standup. The two drifted, and every streaming fix
/// had to be applied twice.
///
/// One shared request type means one implementation of the streaming
/// workflow, with the indexer-specific shape handled here at the boundary.
class StreamRequest {
  /// Human-readable label for logs and the prep overlay.
  final String displayName;

  final String magnetUri;
  final String infoHash;

  /// Index of the target file within a multi-file torrent, when the indexer
  /// told us which one to play. Null means "single-file torrent" — pick the
  /// largest video.
  final int? fileIdx;

  /// Target filename within a multi-file torrent, used as a fallback match
  /// when [fileIdx] is absent or out of range.
  final String? filename;

  /// True when the torrent holds exactly one playable file.
  final bool isSingleFile;

  /// True when the torrent holds several *episodes*, so every non-target
  /// file should be deprioritised to avoid pulling the whole season.
  ///
  /// Deliberately distinct from `!isSingleFile`: a release with one video
  /// plus a `.srt` and a sample is multi-file but is not a season pack, and
  /// zeroing priorities on it buys nothing.
  final bool isSeasonPack;

  const StreamRequest({
    required this.displayName,
    required this.magnetUri,
    required this.infoHash,
    required this.isSingleFile,
    required this.isSeasonPack,
    this.fileIdx,
    this.filename,
  });

  /// From a Torrentio stream — the browse → pick-a-source path.
  factory StreamRequest.fromTorrentio(TorrentioStream stream) {
    return StreamRequest(
      displayName: stream.name,
      magnetUri: stream.magnetUri,
      infoHash: stream.infoHash,
      fileIdx: stream.fileIdx,
      filename: stream.filename,
      isSingleFile: stream.isSingleFile,
      isSeasonPack: stream.isSeasonPack,
    );
  }

  /// From an EZTV torrent — the auto-download / next-episode path.
  ///
  /// `AutoDownloadService.findTorrentForEpisode` returns this type for both
  /// real EZTV results and Torrentio results it converted, so `fileIdx` may
  /// carry a season-pack file index that originated at Torrentio.
  ///
  /// Note the magnet is taken verbatim rather than rebuilt from the info
  /// hash: EZTV magnets carry their own tracker list, and reconstructing one
  /// from the hash alone would drop it.
  factory StreamRequest.fromEztv(EztvTorrent torrent) {
    final hasFileIndex = torrent.fileIdx != null;
    return StreamRequest(
      displayName: torrent.title.isNotEmpty ? torrent.title : torrent.filename,
      magnetUri: torrent.magnetUrl,
      infoHash: torrent.hash,
      fileIdx: torrent.fileIdx,
      filename: torrent.filename.isEmpty ? null : torrent.filename,
      isSingleFile: !hasFileIndex,
      // We only ever get a fileIdx here when the resolver picked one file out
      // of several episodes, so treat that as a pack and let the service
      // deprioritise the rest. Without a fileIdx there is nothing to select.
      isSeasonPack: hasFileIndex,
    );
  }
}
