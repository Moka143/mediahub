import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/widgets/media/poster_lookup.dart';

WatchProgress _progress(
  String path, {
  String? showName,
  int? season,
  int? episode,
  String? episodeCode,
  String? posterPath,
}) => WatchProgress(
  fileHash: WatchProgress.generateHash(path),
  filePath: path,
  showName: showName,
  seasonNumber: season,
  episodeNumber: episode,
  episodeCode: episodeCode,
  posterPath: posterPath,
  position: const Duration(minutes: 10),
  duration: const Duration(minutes: 100),
  lastWatched: DateTime(2026),
);

LocalMediaFile _file(
  String path, {
  String? showName,
  int? season,
  int? episode,
}) => LocalMediaFile(
  path: path,
  fileName: path.split('/').last,
  sizeBytes: 1 << 30,
  modifiedDate: DateTime(2026),
  extension: 'mkv',
  showName: showName,
  seasonNumber: season,
  episodeNumber: episode,
);

void main() {
  group('poster queries', () {
    test('a file and its progress entry ask TMDB the same question', () {
      // Home and the Library used different title cleaners, so one file
      // could get two different posters depending on the screen.
      const moviePath = '/dl/Arrival.2016.1080p.BluRay.x264.mkv';
      expect(
        posterQueryForProgress(_progress(moviePath)),
        posterQueryForFile(_file(moviePath)),
      );

      const episodePath = '/dl/Silo.S02E03.1080p.WEB.mkv';
      expect(
        posterQueryForProgress(
          _progress(episodePath, showName: 'Silo', season: 2, episode: 3),
        ),
        posterQueryForFile(
          _file(episodePath, showName: 'Silo', season: 2, episode: 3),
        ),
      );
    });

    test('episodes search shows by show name; everything else is a movie', () {
      expect(
        posterQueryForFile(
          _file('/dl/x.mkv', showName: 'Silo', season: 1, episode: 1),
        ),
        const PosterQuery.show('Silo'),
      );
      expect(
        posterQueryForFile(_file('/dl/Arrival.2016.1080p.mkv')),
        const PosterQuery.movie('Arrival'),
      );
    });

    test('torrent names are cut at the first release marker', () {
      expect(
        posterQueryForTorrent('The.Bear.S03E02.1080p.WEB.h264-ETHEL'),
        const PosterQuery.show('The Bear'),
      );
      expect(
        posterQueryForTorrent('Dune.Part.Two.2024.2160p.UHD.mkv'),
        const PosterQuery.movie('Dune Part Two'),
      );
    });
  });

  group('watchProgressTitle', () {
    test('a movie is never "Untitled"', () {
      expect(
        watchProgressTitle(_progress('/dl/Arrival.2016.1080p.BluRay.mkv')),
        'Arrival',
      );
    });

    test('a show uses its name', () {
      expect(
        watchProgressTitle(
          _progress('/dl/x.mkv', showName: 'Silo', season: 1, episode: 2),
        ),
        'Silo',
      );
    });

    test('falls back to the file name when nothing is recognisable', () {
      expect(watchProgressTitle(_progress('/dl/1080p.mkv')), isNotEmpty);
    });
  });

  test('TMDB originals are sized down; other URLs pass through', () {
    expect(
      tmdbResized('https://image.tmdb.org/t/p/original/abc.jpg'),
      'https://image.tmdb.org/t/p/w1280/abc.jpg',
    );
    expect(
      tmdbResized('https://image.tmdb.org/t/p/w500/abc.jpg'),
      'https://image.tmdb.org/t/p/w500/abc.jpg',
    );
    expect(tmdbResized(null), isNull);
  });

  test('tmdbImageUrl builds a URL once and never double-prefixes', () {
    expect(tmdbImageUrl('/abc.jpg'), 'https://image.tmdb.org/t/p/w500/abc.jpg');
    expect(
      tmdbImageUrl('https://image.tmdb.org/t/p/w500/abc.jpg'),
      'https://image.tmdb.org/t/p/w500/abc.jpg',
    );
    expect(tmdbImageUrl(''), isNull);
  });
}
