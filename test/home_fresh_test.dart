import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/screens/home/home_cards.dart';

Torrent _torrent(
  String name, {
  int completionOn = 0,
  int addedOn = 0,
  String state = 'uploading',
  String contentPath = '',
}) => Torrent.fromJson({
  'hash': name,
  'name': name,
  'progress': 1.0,
  'state': state,
  'completion_on': completionOn,
  'added_on': addedOn,
  'content_path': contentPath,
});

LocalMediaFile _file(String path, {int size = 1 << 30}) => LocalMediaFile(
  path: path,
  fileName: path.split('/').last,
  sizeBytes: size,
  modifiedDate: DateTime(2026),
  extension: 'mkv',
);

void main() {
  group('freshlyDownloaded', () {
    test('orders by when each download finished', () {
      final fresh = freshlyDownloaded([
        _torrent('a', completionOn: 100),
        _torrent('b', completionOn: 300),
        _torrent('c', completionOn: 200),
      ]);
      expect(fresh.map((t) => t.name), ['b', 'c', 'a']);
    });

    test('without completion times (the built-in engine) the newest-added '
        'comes first', () {
      final fresh = freshlyDownloaded([
        _torrent('oldest'),
        _torrent('middle'),
        _torrent('newest'),
      ]);
      expect(fresh.map((t) => t.name), ['newest', 'middle', 'oldest']);
    });

    test('leaves out anything unfinished, and stops at the limit', () {
      final fresh = freshlyDownloaded([
        _torrent('partial', state: 'downloading'),
        for (var i = 0; i < 10; i++) _torrent('done $i', completionOn: i),
      ], limit: 8);
      expect(fresh, hasLength(8));
      expect(fresh.any((t) => t.name == 'partial'), isFalse);
    });
  });

  group('libraryFileForTorrent', () {
    test('a single-file torrent is the file it is named after', () {
      final file = _file('/dl/Arrival.2016.1080p.mkv');
      expect(
        libraryFileForTorrent(
          _torrent('Arrival.2016.1080p.mkv', contentPath: '/dl'),
          [_file('/dl/Other.Movie.mkv'), file],
        ),
        file,
      );
    });

    test('a folder torrent plays its largest video', () {
      final feature = _file('/dl/Pack/feature.mkv', size: 4 << 30);
      expect(
        libraryFileForTorrent(_torrent('Pack', contentPath: '/dl/Pack'), [
          _file('/dl/Pack/sample.mkv', size: 50 << 20),
          feature,
          _file('/dl/Other/feature.mkv', size: 8 << 30),
        ]),
        feature,
      );
    });

    test('a shared download folder is no answer — it would match '
        'everything', () {
      expect(
        libraryFileForTorrent(_torrent('Pack', contentPath: '/dl'), [
          _file('/dl/a.mkv'),
          _file('/dl/b.mkv'),
        ]),
        isNull,
      );
    });
  });

  test('fresh titles name the show and the episode', () {
    expect(freshTitle('The.Bear.S03E02.1080p.WEB.h264'), 'The Bear S03E02');
    expect(freshTitle('Arrival.2016.1080p.BluRay.mkv'), 'Arrival');
  });
}
