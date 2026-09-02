import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/widgets/player/up_next_chip.dart';

/// The Up Next chip's rules, which used to be `??` chains and inline
/// conditionals inside `video_player_screen.dart`'s `build()`.
///
/// The only way to check any of this was to watch an episode to the credits
/// with a real torrent behind it, which is why the two sources — a file
/// already on disk versus a TMDB answer for one that is not — had drifted
/// into subtly different shapes.
void main() {
  LocalMediaFile file({
    String name = 'Severance.S02E04.1080p.mkv',
    String? showName,
    int? season,
    int? episode,
  }) {
    return LocalMediaFile(
      path: '/library/$name',
      fileName: name,
      sizeBytes: 4 * 1024 * 1024,
      modifiedDate: DateTime(2026, 1, 1),
      showName: showName,
      seasonNumber: season,
      episodeNumber: episode,
      extension: 'mkv',
    );
  }

  Episode tmdbEpisode({
    int season = 2,
    int episode = 4,
    String name = 'Woe\'s Hollow',
  }) {
    return Episode(
      id: 1,
      seasonNumber: season,
      episodeNumber: episode,
      name: name,
    );
  }

  group('visibility', () {
    test('nothing shows while the planner is not offering', () {
      expect(
        UpNextChip.resolve(
          overlayActive: false,
          downloaded: file(showName: 'Severance', season: 2, episode: 4),
          fromTmdb: tmdbEpisode(),
          countdownSeconds: 10,
        ),
        isNull,
      );
    });

    test('nothing shows when neither source knows a next episode', () {
      // Reached constantly: the planner offers as soon as playback passes the
      // final tenth, which is usually before the TMDB lookup has answered.
      expect(
        UpNextChip.resolve(
          overlayActive: true,
          downloaded: null,
          fromTmdb: null,
          countdownSeconds: 10,
        ),
        isNull,
      );
    });
  });

  group('an episode already on disk', () {
    test('plays, and counts down', () {
      final chip = UpNextChip.resolve(
        overlayActive: true,
        downloaded: file(showName: 'Severance', season: 2, episode: 4),
        fromTmdb: null,
        countdownSeconds: 10,
      )!;
      expect(chip.playsFromDisk, isTrue);
      expect(chip.playLabel, 'Play');
      expect(chip.countdownSeconds, 10);
      expect(chip.episodeCode, 'S02E04');
      expect(chip.title, 'Severance');
    });

    test('wins over a TMDB answer for the same slot', () {
      // Both are set for a moment after the prefetch resolves: the session
      // hands back a file and the TMDB episode has not been cleared yet.
      final chip = UpNextChip.resolve(
        overlayActive: true,
        downloaded: file(showName: 'Severance', season: 2, episode: 4),
        fromTmdb: tmdbEpisode(),
        countdownSeconds: 10,
      )!;
      expect(chip.playsFromDisk, isTrue);
      expect(chip.title, 'Severance');
    });

    test('falls back to the file name when the show name never parsed', () {
      final chip = UpNextChip.resolve(
        overlayActive: true,
        downloaded: file(name: 'unparseable.mkv', season: 1, episode: 2),
        fromTmdb: null,
        countdownSeconds: 10,
      )!;
      expect(chip.title, 'unparseable.mkv');
    });

    test('carries an empty code when the file has no season or episode', () {
      // A movie-shaped file, or a download whose name defeated the parser.
      // The overlay expects '' rather than null here.
      final chip = UpNextChip.resolve(
        overlayActive: true,
        downloaded: file(showName: 'Severance'),
        fromTmdb: null,
        countdownSeconds: 10,
      )!;
      expect(chip.episodeCode, '');
    });
  });

  group('an episode only TMDB knows about', () {
    test('streams, and does not count down', () {
      // There is nothing to advance *to* yet — a countdown would expire on a
      // file that has not started downloading.
      final chip = UpNextChip.resolve(
        overlayActive: true,
        downloaded: null,
        fromTmdb: tmdbEpisode(),
        countdownSeconds: 10,
      )!;
      expect(chip.playsFromDisk, isFalse);
      expect(chip.playLabel, 'Stream');
      expect(chip.countdownSeconds, isNull);
      expect(chip.episodeCode, 'S02E04');
      expect(chip.title, "Woe's Hollow");
    });

    test('pads the episode code to two digits', () {
      final chip = UpNextChip.resolve(
        overlayActive: true,
        downloaded: null,
        fromTmdb: tmdbEpisode(season: 1, episode: 9),
        countdownSeconds: 10,
      )!;
      expect(chip.episodeCode, 'S01E09');
    });
  });
}
