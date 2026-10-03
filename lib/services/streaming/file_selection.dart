import 'package:collection/collection.dart';

import '../../models/local_media_file.dart' show videoExtensions;
import '../../models/stream_request.dart';
import '../../models/torrent_file.dart';
import '../../utils/media_names.dart';
import '../../utils/platform_utils.dart';

/// Whether [name] — a file name or a path within a torrent — is a video this
/// app plays. Uses the library's own extension list, so a file the stream
/// will play is also one the library will show.
bool isVideoName(String name) {
  final base = basenameOf(name);
  final dot = base.lastIndexOf('.');
  if (dot < 0) return false;
  return videoExtensions.contains(base.substring(dot + 1).toLowerCase());
}

/// Index of the file in [files] to stream for [request], or null when the
/// torrent holds no video.
///
/// In order of trust: the index the indexer gave, the file name it gave, the
/// episode code, and finally the largest video. A request the indexer called
/// single-file goes straight to the largest video.
int? selectStreamFile({
  required StreamRequest request,
  required List<TorrentFile> files,
  int? season,
  int? episode,
}) {
  int? largestVideo() => files.indexed
      .where((entry) => isVideoName(entry.$2.name))
      .sorted((a, b) => b.$2.size.compareTo(a.$2.size))
      .firstOrNull
      ?.$1;

  if (request.isSingleFile) return largestVideo();

  final fileIdx = request.fileIdx;
  if (fileIdx != null && fileIdx >= 0 && fileIdx < files.length) {
    return fileIdx;
  }

  final wanted = request.filename;
  if (wanted != null && wanted.isNotEmpty) {
    final target = basenameOf(wanted).toLowerCase();
    final byName = files.indexed.firstWhereOrNull(
      (entry) => basenameOf(entry.$2.name).toLowerCase() == target,
    );
    if (byName != null) return byName.$1;
  }

  if (season != null && episode != null) {
    // `nameHasEpisode`, not a hand-written pattern: the old one had no end
    // boundary, so a request for S01E01 could pick S01E10.
    final byEpisode = files.indexed.firstWhereOrNull(
      (entry) =>
          isVideoName(entry.$2.name) &&
          nameHasEpisode(basenameOf(entry.$2.name), season, episode),
    );
    if (byEpisode != null) return byEpisode.$1;
  }

  return largestVideo();
}

/// The files to stop downloading so a season pack does not pull every
/// episode to play one: everything still wanted and unfinished except
/// [target] and the files in [protectedIndexes] — those another streaming
/// session is playing right now.
///
/// Finished files are left alone: re-prioritising one can kick qBittorrent
/// into a recheck, and there is nothing left to save.
List<int> filesToDeselect({
  required List<TorrentFile> files,
  required int target,
  Set<int> protectedIndexes = const {},
}) => [
  for (var i = 0; i < files.length; i++)
    if (i != target &&
        !protectedIndexes.contains(i) &&
        files[i].priority > 0 &&
        !files[i].isNearlyComplete)
      i,
];

/// Whether this session may deselect the other files of a torrent at all.
///
/// Yes when it added the torrent itself. Yes when the torrent is already
/// managed file by file — something deselected part of it before, which is
/// what an earlier streaming session (or an auto-download of one episode)
/// leaves behind. No when every file is still wanted and the torrent was
/// already there: someone queued the whole pack to download, and streaming
/// one episode of it is no reason to quietly cancel the rest.
bool mayTrimTorrent({
  required bool addedBySession,
  required List<TorrentFile> files,
}) => addedBySession || files.any((file) => file.priority == 0);
