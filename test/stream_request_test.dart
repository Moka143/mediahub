import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/eztv_torrent.dart';
import 'package:mediahub/models/stream_request.dart';
import 'package:mediahub/models/torrentio_stream.dart';

void main() {
  group('StreamRequest.fromTorrentio', () {
    test('a stream with no fileIdx is single-file and not a pack', () {
      final request = StreamRequest.fromTorrentio(
        TorrentioStream(
          name: 'Torrentio\n1080p',
          title: 'Show.S01E01.1080p.WEB-DL',
          infoHash: 'abc123',
        ),
      );

      expect(request.isSingleFile, isTrue);
      expect(request.isSeasonPack, isFalse);
      expect(request.fileIdx, isNull);
      expect(request.infoHash, 'abc123');
      expect(request.magnetUri, contains('urn:btih:abc123'));
    });

    test('a multi-file release with subs is not treated as a season pack', () {
      // fileIdx is set because the torrent also holds a .srt — zeroing
      // priorities on it would buy nothing.
      final request = StreamRequest.fromTorrentio(
        TorrentioStream(
          name: 'Torrentio',
          title: 'Show.S01E01.1080p.WEB-DL',
          infoHash: 'abc123',
          fileIdx: 0,
          filename: 'Show.S01E01.1080p.WEB-DL.mkv',
        ),
      );

      expect(request.isSingleFile, isFalse);
      expect(request.isSeasonPack, isFalse);
      expect(request.fileIdx, 0);
    });

    test('a true season pack is flagged so other files get deprioritised', () {
      final request = StreamRequest.fromTorrentio(
        TorrentioStream(
          name: 'Torrentio',
          title: 'Show.S01.Complete.1080p.WEB-DL',
          infoHash: 'abc123',
          fileIdx: 3,
          filename: 'Show.S01E04.1080p.WEB-DL.mkv',
        ),
      );

      expect(request.isSingleFile, isFalse);
      expect(request.isSeasonPack, isTrue);
      expect(request.fileIdx, 3);
    });

    test('magnet carries the tracker list from sources', () {
      final request = StreamRequest.fromTorrentio(
        TorrentioStream(
          name: 'Torrentio',
          title: 'Show.S01E01',
          infoHash: 'abc123',
          sources: ['tracker:udp://tracker.example:1337', 'dht:abc123'],
        ),
      );

      expect(request.magnetUri, contains('tr='));
      expect(request.magnetUri, contains('tracker.example'));
    });
  });

  group('StreamRequest.fromEztv', () {
    EztvTorrent torrent({int? fileIdx, String title = 'Show S01E01 1080p'}) {
      return EztvTorrent(
        id: 1,
        hash: 'def456',
        filename: 'Show.S01E01.1080p.mkv',
        magnetUrl: 'magnet:?xt=urn:btih:def456&tr=udp%3A%2F%2Ftracker%3A1337',
        title: title,
        fileIdx: fileIdx,
      );
    }

    test('no fileIdx means single-file, nothing to select', () {
      final request = StreamRequest.fromEztv(torrent());

      expect(request.isSingleFile, isTrue);
      expect(request.isSeasonPack, isFalse);
      expect(request.fileIdx, isNull);
    });

    test('a fileIdx means one episode was picked out of several', () {
      final request = StreamRequest.fromEztv(torrent(fileIdx: 5));

      expect(request.isSingleFile, isFalse);
      expect(request.isSeasonPack, isTrue);
      expect(request.fileIdx, 5);
    });

    test('takes the magnet verbatim rather than rebuilding it', () {
      // EZTV magnets carry their own tracker list. Reconstructing one from
      // the info hash alone would silently drop it and leave the torrent
      // relying on DHT.
      final t = torrent();
      final request = StreamRequest.fromEztv(t);

      expect(request.magnetUri, t.magnetUrl);
      expect(request.magnetUri, contains('tr='));
    });

    test('falls back to the filename when the title is empty', () {
      final request = StreamRequest.fromEztv(torrent(title: ''));

      expect(request.displayName, 'Show.S01E01.1080p.mkv');
    });

    test('an empty filename becomes null rather than an empty match key', () {
      final request = StreamRequest.fromEztv(
        EztvTorrent(
          id: 1,
          hash: 'def456',
          filename: '',
          magnetUrl: 'magnet:?xt=urn:btih:def456',
          title: 'Show S01E01',
        ),
      );

      expect(request.filename, isNull);
    });
  });
}
