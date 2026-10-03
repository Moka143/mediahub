import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/torrent_file.dart';

/// A contiguous, inclusive run of file-relative byte offsets.
///
/// Produced by [FilePieceMap.availableRanges] to describe *where* a
/// partially-downloaded file actually has data. A single `progress` fraction
/// cannot express this: pieces land out of order whenever the engine is not
/// downloading sequentially, so "60% downloaded" says nothing about which 60%.
@immutable
class ByteRange {
  const ByteRange(this.start, this.end);

  /// First byte of the run, file-relative.
  final int start;

  /// Last byte of the run, inclusive.
  final int end;

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ByteRange($start-$end)';
}

/// Where one file sits in its torrent's piece space.
///
/// Pieces belong to the *torrent*, not to the file: piece `i` covers torrent
/// bytes `[i·pieceSize, (i+1)·pieceSize)`, and a file starts wherever the
/// files before it end. In a season pack that is almost never on a piece
/// boundary, so the first piece of most episodes is shared with the tail of
/// the previous one.
///
/// Every conversion here goes through the file's torrent offset for that
/// reason. The code this replaces assumed file byte 0 was the first byte of
/// the file's first piece, which put every boundary up to one piece *late*:
/// with piece 87 done and 88 missing it reported the first four megabytes of
/// an episode as on disk when only the first one was, and the proxy served
/// three megabytes of sparse zeros straight into the demuxer.
///
/// The offset may be known only to within [offsetUncertainty] bytes (see
/// [PieceGeometry.forFile]). A byte then counts as downloaded only when every
/// piece it could be in is complete — getting the offset wrong in *either*
/// direction can otherwise pair a byte with a finished neighbour of its real,
/// unfinished piece.
@immutable
class FilePieceMap {
  const FilePieceMap({
    required this.pieceSize,
    required this.fileOffset,
    required this.fileSize,
    this.offsetUncertainty = 0,
  }) : assert(pieceSize > 0),
       assert(fileOffset >= 0),
       assert(fileSize > 0),
       assert(offsetUncertainty >= 0);

  /// Bytes per piece, torrent-wide.
  final int pieceSize;

  /// Torrent-relative offset of the file's first byte — the earliest it can
  /// be, when [offsetUncertainty] is not zero.
  final int fileOffset;

  /// Length of the file in bytes.
  final int fileSize;

  /// How much later than [fileOffset] the file may really start. Zero when
  /// the offset is exact.
  final int offsetUncertainty;

  int get _latestOffset => fileOffset + offsetUncertainty;

  /// The first piece that can hold any of this file.
  int get firstPiece => fileOffset ~/ pieceSize;

  /// The last piece that can hold any of this file.
  int get lastPiece => (_latestOffset + fileSize - 1) ~/ pieceSize;

  static bool _done(List<int> pieceStates, int piece) =>
      piece >= 0 && piece < pieceStates.length && pieceStates[piece] == 2;

  /// The first file-relative byte at or after [from] that is not certainly
  /// inside a completed piece, or [fileSize] when everything from [from] on is
  /// there.
  ///
  /// Returns [from] itself when the piece holding it is missing. A piece map
  /// shorter than the file reads as "missing" from where it ends.
  int firstUnavailableFrom(int from, List<int> pieceStates) {
    if (from >= fileSize) return fileSize;
    final start = from < 0 ? 0 : from;
    for (
      var piece = (fileOffset + start) ~/ pieceSize;
      piece <= lastPiece;
      piece++
    ) {
      if (!_done(pieceStates, piece)) {
        // The first byte that may live in this piece, at the latest offset.
        final firstAffected = piece * pieceSize - _latestOffset;
        return firstAffected <= start
            ? start
            : math.min(firstAffected, fileSize);
      }
    }
    return fileSize;
  }

  /// Every downloaded run of the file, in file-relative bytes.
  ///
  /// The seek bar draws these, and the playback monitor uses them to tell a
  /// seek into a hole from playback catching up with the download.
  List<ByteRange> availableRanges(List<int> pieceStates) {
    final ranges = <ByteRange>[];
    int? runStart;

    void close(int lastDonePiece) {
      final first = runStart;
      if (first == null) return;
      runStart = null;
      // Bytes whose every candidate piece lies inside [first, lastDonePiece].
      final start = math.max(0, first * pieceSize - fileOffset);
      final end = math.min(
        fileSize - 1,
        (lastDonePiece + 1) * pieceSize - 1 - _latestOffset,
      );
      if (end >= start) ranges.add(ByteRange(start, end));
    }

    for (var i = firstPiece; i <= lastPiece; i++) {
      if (_done(pieceStates, i)) {
        runStart ??= i;
      } else {
        close(i - 1);
      }
    }
    close(lastPiece);
    return ranges;
  }

  /// Whether the first [bytes] of the file — or all of it, when it is
  /// shorter — are downloaded.
  bool headReady(List<int> pieceStates, {required int bytes}) =>
      firstUnavailableFrom(0, pieceStates) >= math.min(bytes, fileSize);

  @override
  bool operator ==(Object other) =>
      other is FilePieceMap &&
      other.pieceSize == pieceSize &&
      other.fileOffset == fileOffset &&
      other.fileSize == fileSize &&
      other.offsetUncertainty == offsetUncertainty;

  @override
  int get hashCode =>
      Object.hash(pieceSize, fileOffset, fileSize, offsetUncertainty);

  @override
  String toString() =>
      'FilePieceMap(offset $fileOffset'
      '${offsetUncertainty == 0 ? '' : '+$offsetUncertainty'}, '
      'size $fileSize, pieces $firstPiece-$lastPiece of ${pieceSize}B)';
}

/// The one place a file's [FilePieceMap] is worked out.
///
/// Streaming readiness, the streaming proxy and the playback monitor all need
/// it, and each used to carry its own copy of the lookup — three copies of the
/// same misalignment.
abstract final class PieceGeometry {
  /// Resolve the map for [fileIndex] of a torrent whose file list, in torrent
  /// order, is [files].
  ///
  /// The offset is the sum of the sizes of the files before it. That is exact
  /// when the engine lists every file — rqbit does, padding files included.
  /// qBittorrent hides BEP 47 padding files from its list but reports each
  /// file's real `piece_range`; when the two disagree the list is missing
  /// bytes, and the offset becomes the interval the reported range allows
  /// (see [FilePieceMap.offsetUncertainty]).
  ///
  /// Null when there is nothing to map: no piece size yet, an index out of
  /// range, an empty file, or a reported range no offset can satisfy.
  static FilePieceMap? forFile({
    required List<TorrentFile> files,
    required int fileIndex,
    required int pieceSize,
  }) => forSizes(
    fileSizes: [for (final f in files) f.size],
    fileIndex: fileIndex,
    pieceSize: pieceSize,
    listedRange: fileIndex >= 0 && fileIndex < files.length
        ? files[fileIndex].pieceRange
        : null,
  );

  /// [forFile], from bare sizes. Separate so the arithmetic can be tested
  /// without building [TorrentFile]s.
  static FilePieceMap? forSizes({
    required List<int> fileSizes,
    required int fileIndex,
    required int pieceSize,
    List<int>? listedRange,
  }) {
    if (pieceSize <= 0 || fileIndex < 0 || fileIndex >= fileSizes.length) {
      return null;
    }
    final size = fileSizes[fileIndex];
    if (size <= 0) return null;

    var offset = 0;
    for (var i = 0; i < fileIndex; i++) {
      offset += math.max(0, fileSizes[i]);
    }

    if (listedRange == null || listedRange.length < 2) {
      return FilePieceMap(
        pieceSize: pieceSize,
        fileOffset: offset,
        fileSize: size,
      );
    }

    final first = listedRange[0];
    final last = listedRange[1];
    if (offset ~/ pieceSize == first &&
        (offset + size - 1) ~/ pieceSize == last) {
      return FilePieceMap(
        pieceSize: pieceSize,
        fileOffset: offset,
        fileSize: size,
      );
    }

    // The listed range is the engine's own word on where the file is. Every
    // offset consistent with it lies in [earliest, latest].
    final earliest = math.max(first * pieceSize, last * pieceSize - size + 1);
    final latest = math.min(
      (first + 1) * pieceSize - 1,
      (last + 1) * pieceSize - size,
    );
    if (first < 0 || latest < earliest) return null;
    return FilePieceMap(
      pieceSize: pieceSize,
      fileOffset: earliest,
      fileSize: size,
      offsetUncertainty: latest - earliest,
    );
  }
}
