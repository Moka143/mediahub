import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/local_media_file.dart';
import '../../utils/platform_utils.dart';
import '../app_logger.dart';
import 'file_selection.dart';

/// Where a streaming session's video is on disk.
///
/// [exists] is false when nothing is there yet. That is fatal for a source
/// that reads the file (the proxy, or the disk itself), but not for an engine
/// that serves the stream over HTTP — it may simply not have created the file
/// yet.
typedef LocatedVideo = ({LocalMediaFile file, bool exists});

/// The path of a torrent file on disk: the torrent's save path joined with
/// the file's path inside the torrent.
///
/// Both engines report file names relative to the save path — qBittorrent's
/// include the torrent's root folder, rqbit's output folder is already the
/// torrent's own. This used to start from qBittorrent's `content_path`
/// instead, which for a multi-file torrent *is* `<save path>/<root folder>`,
/// so the root folder appeared twice, the file was never found, and the
/// fallback search picked the first file anywhere in the pack with the same
/// name — `Season 1/Episode 01.mkv` played for S02E01.
String torrentFilePath(String savePath, String nameInTorrent) {
  final segments = nameInTorrent
      .split(RegExp(r'[\\/]'))
      .where((s) => s.isNotEmpty);
  return p.normalize(p.join(savePath, p.joinAll(segments)));
}

/// Find a torrent file on disk, describe it as a [LocalMediaFile], and say
/// whether it is really there.
///
/// Tries the exact path first. Failing that, it searches under the torrent's
/// [contentPath] (or [savePath]) for a file whose path *ends with* the path
/// inside the torrent, and only then for a lone file of the same name —
/// never the first of several, which is how a pack with a folder per season
/// used to hand back the wrong season.
Future<LocatedVideo> locateTorrentFile({
  required String savePath,
  required String? contentPath,
  required String nameInTorrent,
  String? showName,
  int? season,
  int? episode,
  String? torrentHash,
}) async {
  final expected = torrentFilePath(savePath, nameInTorrent);
  var path = expected;
  var stat = await FileStat.stat(path);

  if (stat.type != FileSystemEntityType.file) {
    final found = await _search(
      root: contentPath != null && contentPath.isNotEmpty
          ? contentPath
          : savePath,
      nameInTorrent: nameInTorrent,
    );
    if (found != null) {
      path = found;
      stat = await FileStat.stat(path);
    }
  }

  final exists = stat.type == FileSystemEntityType.file;
  final fileName = p.basename(path);
  return (
    file: LocalMediaFile(
      path: path,
      fileName: fileName,
      sizeBytes: exists ? stat.size : 0,
      modifiedDate: exists ? stat.modified : DateTime.now(),
      extension: p.extension(fileName).replaceFirst('.', ''),
      showName: showName,
      seasonNumber: season,
      episodeNumber: episode,
      torrentHash: torrentHash,
    ),
    exists: exists,
  );
}

Future<String?> _search({
  required String root,
  required String nameInTorrent,
}) async {
  // A single-file torrent's content path is the file itself.
  if (await FileSystemEntity.type(root) == FileSystemEntityType.file) {
    return p.basename(root).toLowerCase() ==
            basenameOf(nameInTorrent).toLowerCase()
        ? root
        : null;
  }

  final dir = Directory(root);
  if (!await dir.exists()) return null;

  final wantedSegments = nameInTorrent
      .split(RegExp(r'[\\/]'))
      .where((s) => s.isNotEmpty)
      .map((s) => s.toLowerCase())
      .toList();
  if (wantedSegments.isEmpty) return null;
  final wantedName = wantedSegments.last;

  final sameName = <String>[];
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !isVideoName(entity.path)) continue;
      final segments = p
          .split(entity.path)
          .map((s) => s.toLowerCase())
          .toList();
      if (segments.last != wantedName) continue;
      if (_endsWith(segments, wantedSegments)) return entity.path;
      sameName.add(entity.path);
    }
  } catch (e) {
    AppLog.w('[StreamingService] could not search $root: $e');
  }
  // Only an unambiguous name match: with several, picking one is a guess.
  return sameName.length == 1 ? sameName.single : null;
}

bool _endsWith(List<String> path, List<String> suffix) {
  if (suffix.length > path.length) return false;
  final offset = path.length - suffix.length;
  for (var i = 0; i < suffix.length; i++) {
    if (path[offset + i] != suffix[i]) return false;
  }
  return true;
}
