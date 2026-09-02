import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/services/auto_download_service.dart';
import 'package:mediahub/services/eztv_api_service.dart';
import 'package:mediahub/services/qbittorrent_api_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/torrentio_api_service.dart';

/// Tests for the decisions auto-download makes before it fetches anything.
///
/// The indexer search and the qBittorrent add need a live stack and stay out
/// of scope. What is covered is everything that decides *whether* to fetch,
/// and it is worth covering because the failure modes are silent: an
/// over-eager show-name match re-downloads an episode the user already has,
/// and a wrong season-boundary answer either stops binge-watching a show that
/// has more episodes or starts fetching a season that has not aired.
void main() {
  LocalMediaFile downloaded({
    required String showName,
    required int season,
    required int episode,
  }) {
    final code =
        'S${season.toString().padLeft(2, '0')}'
        'E${episode.toString().padLeft(2, '0')}';
    return LocalMediaFile(
      path: '/library/$showName.$code.mkv',
      fileName: '$showName.$code.mkv',
      sizeBytes: 900 * 1024 * 1024,
      modifiedDate: DateTime(2026, 1, 1),
      showName: showName,
      seasonNumber: season,
      episodeNumber: episode,
      extension: 'mkv',
    );
  }

  Episode episode({
    required int season,
    required int number,
    String? airDate,
    String name = 'Episode',
  }) {
    return Episode(
      id: season * 100 + number,
      seasonNumber: season,
      episodeNumber: number,
      name: name,
      airDate: airDate,
    );
  }

  AutoDownloadService service({
    Show? show,
    Map<int, List<Episode>> seasons = const {},
    List<Torrent> torrents = const [],
  }) {
    return AutoDownloadService(
      tmdbService: _FakeTmdb(show: show, seasons: seasons),
      eztvService: EztvApiService(),
      qbtService: _FakeQbt(torrents),
      torrentioService: TorrentioApiService(),
    );
  }

  String yesterday() => DateTime.now()
      .subtract(const Duration(days: 1))
      .toIso8601String()
      .split('T')
      .first;

  String nextWeek() => DateTime.now()
      .add(const Duration(days: 7))
      .toIso8601String()
      .split('T')
      .first;

  group('isEpisodeDownloaded', () {
    final library = [
      downloaded(showName: 'Severance', season: 2, episode: 4),
      downloaded(showName: 'The Bear', season: 3, episode: 1),
    ];

    test('finds an episode that is already on disk', () {
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: library,
          showName: 'Severance',
          season: 2,
          episode: 4,
        ),
        isTrue,
      );
    });

    test('does not match a different episode of the same show', () {
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: library,
          showName: 'Severance',
          season: 2,
          episode: 5,
        ),
        isFalse,
      );
    });

    test('does not match the same episode number in another season', () {
      // S03E04 and S02E04 differ only in the season, and the episode code is
      // the whole discriminator once the show name matches.
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: library,
          showName: 'Severance',
          season: 3,
          episode: 4,
        ),
        isFalse,
      );
    });

    test('ignores case in the show name', () {
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: library,
          showName: 'SEVERANCE',
          season: 2,
          episode: 4,
        ),
        isTrue,
      );
    });

    test('matches across a leading article', () {
      // The scanner parses "The Bear" from some releases and "Bear" from
      // others; both must resolve to the same show.
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: library,
          showName: 'Bear',
          season: 3,
          episode: 1,
        ),
        isTrue,
      );
    });

    test('matches across punctuation differences', () {
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: [
            downloaded(
              showName: 'Marvels Agents of SHIELD',
              season: 1,
              episode: 2,
            ),
          ],
          showName: 'Marvel\'s Agents of S.H.I.E.L.D.',
          season: 1,
          episode: 2,
        ),
        isTrue,
      );
    });

    test('an empty library is never a match', () {
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: const [],
          showName: 'Severance',
          season: 2,
          episode: 4,
        ),
        isFalse,
      );
    });

    test('a file with no parsed show name is not matched by accident', () {
      // `fileShowName` is '' for these, and '' is a substring of everything —
      // the guard that keeps a bare `contains` from matching every show.
      final unparsed = LocalMediaFile(
        path: '/library/unknown.mkv',
        fileName: 'unknown.mkv',
        sizeBytes: 1,
        modifiedDate: DateTime(2026, 1, 1),
        seasonNumber: 2,
        episodeNumber: 4,
        extension: 'mkv',
      );
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: [unparsed],
          showName: 'Severance',
          season: 2,
          episode: 4,
        ),
        isFalse,
        reason: 'an unnamed file must not satisfy every show',
      );
    });
  });

  group('getNextEpisode', () {
    test('returns the next episode in the current season', () async {
      final result = await service(
        show: Show(id: 1, name: 'Severance', numberOfSeasons: 2),
        seasons: {
          2: [
            episode(season: 2, number: 4, airDate: yesterday()),
            episode(season: 2, number: 5, airDate: yesterday()),
          ],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 4);

      expect(result.hasNextEpisode, isTrue);
      expect(result.nextEpisode!.episodeNumber, 5);
      expect(result.isSeasonEnd, isFalse);
      expect(result.message, isNull, reason: 'it has aired, nothing to say');
    });

    test('reports an unaired next episode rather than hiding it', () async {
      // The card still offers it so the user knows one is coming; the message
      // is what stops auto-download from chasing a torrent that cannot exist.
      final airs = nextWeek();
      final result = await service(
        show: Show(id: 1, name: 'Severance', numberOfSeasons: 2),
        seasons: {
          2: [
            episode(season: 2, number: 4, airDate: yesterday()),
            episode(season: 2, number: 5, airDate: airs),
          ],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 4);

      expect(result.hasNextEpisode, isTrue);
      expect(result.message, contains(airs));
    });

    test('rolls over to the first episode of the next season', () async {
      final result = await service(
        show: Show(id: 1, name: 'Severance', numberOfSeasons: 3),
        seasons: {
          2: [episode(season: 2, number: 10, airDate: yesterday())],
          3: [episode(season: 3, number: 1, airDate: yesterday())],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.isSeasonEnd, isTrue);
      expect(result.isSeriesEnd, isFalse);
      expect(result.nextEpisode!.seasonNumber, 3);
      expect(result.nextEpisode!.episodeNumber, 1);
      expect(result.isNextSeasonAvailable, isTrue);
      expect(result.nextSeasonNumber, 3);
    });

    test(
      'a next season that has not aired is offered but not available',
      () async {
        final result = await service(
          show: Show(id: 1, name: 'Severance', numberOfSeasons: 3),
          seasons: {
            2: [episode(season: 2, number: 10, airDate: yesterday())],
            3: [episode(season: 3, number: 1, airDate: nextWeek())],
          },
        ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

        expect(result.hasNextEpisode, isTrue);
        expect(result.isNextSeasonAvailable, isFalse);
      },
    );

    test('the last episode of the last season ends the series', () async {
      final result = await service(
        show: Show(id: 1, name: 'Severance', numberOfSeasons: 2),
        seasons: {
          2: [episode(season: 2, number: 10, airDate: yesterday())],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.hasNextEpisode, isFalse);
      expect(result.isSeriesEnd, isTrue);
      expect(result.isSeasonEnd, isTrue);
    });

    test('an announced-but-empty next season is not a series end', () async {
      // TMDB lists the season before it has any episode records. Answering
      // "series ended" here would stop binge-watching an ongoing show.
      final result = await service(
        show: Show(id: 1, name: 'Severance', numberOfSeasons: 3),
        seasons: {
          2: [episode(season: 2, number: 10, airDate: yesterday())],
          3: const [],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.isSeriesEnd, isFalse);
      expect(result.isNextSeasonAvailable, isFalse);
      expect(result.nextSeasonNumber, 3);
    });

    test('a missing air date counts as not aired', () async {
      // TMDB leaves airDate null for unscheduled episodes; treating null as
      // aired would send auto-download after a torrent that cannot exist.
      final result = await service(
        show: Show(id: 1, name: 'Severance', numberOfSeasons: 3),
        seasons: {
          2: [episode(season: 2, number: 10, airDate: yesterday())],
          3: [episode(season: 3, number: 1)],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.isNextSeasonAvailable, isFalse);
    });

    test('a TMDB failure degrades to a message, not a throw', () async {
      // Called from a position subscription during playback; an exception
      // here would surface as an unhandled async error mid-episode.
      final result = await AutoDownloadService(
        tmdbService: _FakeTmdb(throws: true),
        eztvService: EztvApiService(),
        qbtService: _FakeQbt(const []),
        torrentioService: TorrentioApiService(),
      ).getNextEpisode(showId: 1, currentSeason: 1, currentEpisode: 1);

      expect(result.hasNextEpisode, isFalse);
      expect(result.message, contains('Failed to fetch next episode'));
    });
  });

  group('isEpisodeCurrentlyDownloading', () {
    Torrent named(String name) => Torrent(
      hash: 'h',
      name: name,
      size: 0,
      progress: 0.5,
      dlspeed: 0,
      upspeed: 0,
      eta: 0,
      state: 'downloading',
      numSeeds: 0,
      numLeeches: 0,
      ratio: 0,
      addedOn: 0,
      completionOn: 0,
      savePath: '',
      downloaded: 0,
      uploaded: 0,
      numComplete: 0,
      numIncomplete: 0,
      category: '',
      tags: '',
      priority: 0,
      amountLeft: 0,
      tracker: '',
      seenComplete: 0,
      lastActivity: 0,
      totalSize: 0,
      pieceSize: 0,
      piecesNum: 0,
      piecesHave: 0,
      contentPath: '',
      sequentialDownload: false,
      firstLastPiecePriority: false,
    );

    Future<bool> check(List<Torrent> torrents, {int episode = 4}) {
      return service(torrents: torrents).isEpisodeCurrentlyDownloading(
        showName: 'The Bear',
        season: 2,
        episode: episode,
      );
    }

    test('recognises a dot-separated release name', () async {
      expect(await check([named('The.Bear.S02E04.1080p.WEB.mkv')]), isTrue);
    });

    test('recognises a dash-separated release name', () async {
      expect(await check([named('the-bear-s02e04-1080p.mkv')]), isTrue);
    });

    test('does not match a different episode', () async {
      expect(
        await check([named('The.Bear.S02E04.1080p.mkv')], episode: 5),
        isFalse,
      );
    });

    test('does not match another show', () async {
      expect(await check([named('Severance.S02E04.1080p.mkv')]), isFalse);
    });

    test(
      'an unreachable qBittorrent answers no rather than throwing',
      () async {
        // Answering "yes" on an error would suppress a download the user asked
        // for; throwing would break the caller mid-playback.
        final result =
            await AutoDownloadService(
              tmdbService: _FakeTmdb(),
              eztvService: EztvApiService(),
              qbtService: _FakeQbt(const [], throws: true),
              torrentioService: TorrentioApiService(),
            ).isEpisodeCurrentlyDownloading(
              showName: 'The Bear',
              season: 2,
              episode: 4,
            );
        expect(result, isFalse);
      },
    );
  });

  group('EpisodeTrackingInfo', () {
    test('round-trips through JSON', () {
      final info = EpisodeTrackingInfo(
        showId: 95396,
        imdbId: 'tt11280740',
        showName: 'Severance',
        season: 2,
        episode: 4,
        airDate: '2026-01-24',
        status: EpisodeDownloadStatus.downloading,
        quality: '1080p',
        torrentHash: 'abc123',
        magnetLink: 'magnet:?xt=urn:btih:abc123',
      );
      final restored = EpisodeTrackingInfo.fromJson(info.toJson());

      expect(restored.showId, info.showId);
      expect(restored.imdbId, info.imdbId);
      expect(restored.season, info.season);
      expect(restored.episode, info.episode);
      expect(restored.status, EpisodeDownloadStatus.downloading);
      expect(restored.quality, '1080p');
      expect(restored.torrentHash, 'abc123');
      expect(restored.episodeCode, 'S02E04');
    });

    test('a missing status decodes to the first state, not a crash', () {
      // Entries written before `status` existed, and any future enum
      // reordering, come through this path.
      final restored = EpisodeTrackingInfo.fromJson({
        'show_id': 1,
        'show_name': 'Severance',
        'season': 1,
        'episode': 1,
      });
      expect(restored.status, EpisodeDownloadStatus.notAired);
    });
  });
}

class _FakeTmdb extends TmdbApiService {
  _FakeTmdb({this.show, this.seasons = const {}, this.throws = false})
    : super(accessToken: 'test');

  final Show? show;
  final Map<int, List<Episode>> seasons;
  final bool throws;

  @override
  Future<Show> getShowDetails(int showId) async {
    if (throws) throw StateError('TMDB unreachable');
    return show ?? Show(id: showId, name: 'Unknown');
  }

  @override
  Future<List<Episode>> getSeasonEpisodes(int showId, int seasonNumber) async {
    if (throws) throw StateError('TMDB unreachable');
    final found = seasons[seasonNumber];
    if (found == null) throw StateError('no such season');
    return found;
  }
}

class _FakeQbt extends QBittorrentApiService {
  _FakeQbt(this.torrents, {this.throws = false});

  final List<Torrent> torrents;
  final bool throws;

  @override
  Future<List<Torrent>> getTorrents({
    String? filter,
    String? category,
    String? tag,
    String? sort,
    bool? reverse,
    int? limit,
    int? offset,
    List<String>? hashes,
  }) async {
    if (throws) throw StateError('qBittorrent unreachable');
    return torrents;
  }
}
