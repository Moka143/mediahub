import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/episode.dart';
import 'package:mediahub/models/eztv_torrent.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/show.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/models/torrentio_stream.dart';
import 'package:mediahub/services/auto_download_service.dart';
import 'package:mediahub/services/eztv_api_service.dart';
import 'package:mediahub/services/qbittorrent_api_service.dart';
import 'package:mediahub/services/tmdb_api_service.dart';
import 'package:mediahub/services/torrentio_api_service.dart';

/// Tests for the decisions auto-download makes, and the engine conversation
/// it has once it has made them.
///
/// The failure modes here are silent: an over-eager show-name match
/// re-downloads (or never downloads) an episode, an early "aired" searches
/// for a torrent that cannot exist yet, a dead torrent is picked over a
/// healthy one, and a season pack downloads whole.
void main() {
  LocalMediaFile downloaded({
    required String showName,
    required int season,
    required int episode,
    int? showId,
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
      showId: showId,
      extension: 'mkv',
    );
  }

  Episode episode({required int season, required int number, String? airDate}) {
    return Episode(
      id: season * 100 + number,
      seasonNumber: season,
      episodeNumber: number,
      name: 'Episode',
      airDate: airDate,
    );
  }

  /// "Now" for every date-sensitive case: mid-afternoon UTC, 3 Oct 2026.
  final now = DateTime.utc(2026, 10, 3, 15);

  AutoDownloadService service({
    Show? show,
    Map<int, List<Episode>> seasons = const {},
    List<Torrent> torrents = const [],
    bool tmdbThrows = false,
    _FakeEngine? engine,
    _FakeEztv? eztv,
    _FakeTorrentio? torrentio,
    DateTime? clock,
  }) {
    return AutoDownloadService(
      tmdbService: _FakeTmdb(show: show, seasons: seasons, throws: tmdbThrows),
      eztvService: eztv ?? _FakeEztv(),
      engine: engine ?? _FakeEngine(torrents: torrents),
      torrentioService: torrentio ?? _FakeTorrentio(),
      clock: () => clock ?? now,
      metadataPollInterval: Duration.zero,
      metadataTimeout: const Duration(milliseconds: 50),
    );
  }

  group('isEpisodeDownloaded', () {
    final library = [
      downloaded(showName: 'Severance', season: 2, episode: 4),
      downloaded(showName: 'The Bear', season: 3, episode: 1),
      downloaded(showName: 'Dark Matter', season: 1, episode: 1),
      downloaded(showName: 'Young Sheldon', season: 1, episode: 1),
    ];

    bool has(String show, int s, int e, {int? showId}) =>
        service().isEpisodeDownloaded(
          downloadedFiles: library,
          showName: show,
          season: s,
          episode: e,
          showId: showId,
        );

    test('finds an episode that is already on disk', () {
      expect(has('Severance', 2, 4), isTrue);
    });

    test('does not match a different episode of the same show', () {
      expect(has('Severance', 2, 5), isFalse);
      expect(has('Severance', 3, 4), isFalse);
    });

    test('ignores case, punctuation and a leading article', () {
      expect(has('SEVERANCE', 2, 4), isTrue);
      expect(has('Bear', 3, 1), isTrue);
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: [
            downloaded(
              showName: 'Marvels Agents of SHIELD',
              season: 1,
              episode: 2,
            ),
          ],
          showName: "Marvel's Agents of S.H.I.E.L.D.",
          season: 1,
          episode: 2,
        ),
        isTrue,
      );
    });

    test('a show whose name merely contains another is a different show', () {
      // "Dark Matter" S01E01 on disk used to count as "Dark" S01E01, and the
      // real one was never fetched.
      expect(has('Dark', 1, 1), isFalse);
      expect(has('You', 1, 1), isFalse);
    });

    test('the TMDB id decides when both sides have one', () {
      final tagged = [
        downloaded(showName: 'The Office', season: 1, episode: 1, showId: 2316),
      ];
      expect(
        service().isEpisodeDownloaded(
          downloadedFiles: tagged,
          showName: 'The Office',
          season: 1,
          episode: 1,
          showId: 2996, // the UK one
        ),
        isFalse,
      );
    });

    test('a file with no parsed show name is not matched by accident', () {
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
      );
    });
  });

  group('getNextEpisode', () {
    final show = Show(id: 1, name: 'Severance', numberOfSeasons: 3);

    test('returns the next episode in the current season', () async {
      final result = await service(
        show: show,
        seasons: {
          2: [
            episode(season: 2, number: 4, airDate: '2026-09-20'),
            episode(season: 2, number: 5, airDate: '2026-09-27'),
          ],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 4);

      expect(result.nextEpisode!.episodeNumber, 5);
      expect(result.hasAired, isTrue);
      expect(result.message, isNull);
    });

    test('flags an unaired next episode instead of hiding it', () async {
      final result = await service(
        show: show,
        seasons: {
          2: [
            episode(season: 2, number: 4, airDate: '2026-09-27'),
            episode(season: 2, number: 5, airDate: '2026-10-10'),
          ],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 4);

      expect(result.hasNextEpisode, isTrue);
      expect(result.hasAired, isFalse);
      expect(result.message, contains('S02E05'));
    });

    test('an episode dated today has not aired yet', () async {
      // TMDB's date is the US broadcast date — an evening that is already
      // the next day in UTC. Reading it as local midnight called episodes
      // aired up to a day and a half early.
      Future<bool> airedAt(DateTime clock) async =>
          (await service(
                show: show,
                seasons: {
                  2: [
                    episode(season: 2, number: 4, airDate: '2026-09-27'),
                    episode(season: 2, number: 5, airDate: '2026-10-03'),
                  ],
                },
                clock: clock,
              ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 4))
              .hasAired;

      expect(await airedAt(DateTime.utc(2026, 10, 3, 23, 59)), isFalse);
      expect(await airedAt(DateTime.utc(2026, 10, 4, 0, 1)), isTrue);
    });

    test('rolls over to the first episode of the next season', () async {
      final result = await service(
        show: show,
        seasons: {
          2: [episode(season: 2, number: 10, airDate: '2026-01-01')],
          3: [episode(season: 3, number: 1, airDate: '2026-09-01')],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.nextEpisode!.seasonNumber, 3);
      expect(result.nextEpisode!.episodeNumber, 1);
      expect(result.hasAired, isTrue);
      expect(result.isSeriesEnd, isFalse);
    });

    test('the last episode of the last season ends the series', () async {
      final result = await service(
        show: Show(id: 1, name: 'Severance', numberOfSeasons: 2),
        seasons: {
          2: [episode(season: 2, number: 10, airDate: '2026-01-01')],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.hasNextEpisode, isFalse);
      expect(result.isSeriesEnd, isTrue);
      expect(result.lookupFailed, isFalse);
    });

    test('an announced-but-empty next season is not a series end', () async {
      final result = await service(
        show: show,
        seasons: {
          2: [episode(season: 2, number: 10, airDate: '2026-01-01')],
          3: const [],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.hasNextEpisode, isFalse);
      expect(result.isSeriesEnd, isFalse);
    });

    test('a missing air date counts as not aired', () async {
      final result = await service(
        show: show,
        seasons: {
          2: [episode(season: 2, number: 10, airDate: '2026-01-01')],
          3: [episode(season: 3, number: 1)],
        },
      ).getNextEpisode(showId: 1, currentSeason: 2, currentEpisode: 10);

      expect(result.hasAired, isFalse);
    });

    test('a TMDB failure is reported plainly, not thrown', () async {
      final result = await service(
        tmdbThrows: true,
      ).getNextEpisode(showId: 1, currentSeason: 1, currentEpisode: 1);

      expect(result.hasNextEpisode, isFalse);
      expect(result.lookupFailed, isTrue);
      expect(result.message, isNot(contains('Error')));
    });
  });

  group('isEpisodeCurrentlyDownloading', () {
    Future<bool> check(String showName, List<String> names, {int e = 4}) {
      return service(
        torrents: [for (final n in names) _torrent(n)],
      ).isEpisodeCurrentlyDownloading(
        showName: showName,
        season: 2,
        episode: e,
      );
    }

    test('recognises dot- and dash-separated release names', () async {
      expect(
        await check('The Bear', ['The.Bear.S02E04.1080p.WEB.mkv']),
        isTrue,
      );
      expect(await check('The Bear', ['the-bear-s02e04-1080p.mkv']), isTrue);
    });

    test('recognises names with punctuation in them', () async {
      // Spaces became dots and nothing else changed: "Mr. Robot" looked for
      // `mr..robot` and queued a duplicate of `Mr.Robot.S02E04`.
      expect(await check('Mr. Robot', ['Mr.Robot.S02E04.720p.mkv']), isTrue);
      expect(
        await check("Grey's Anatomy", ['Greys.Anatomy.S02E04.mkv']),
        isTrue,
      );
    });

    test('does not match a different episode or show', () async {
      expect(await check('The Bear', ['The.Bear.S02E04.mkv'], e: 5), isFalse);
      expect(await check('The Bear', ['Severance.S02E04.mkv']), isFalse);
      expect(await check('Dark', ['Dark.Matter.S02E04.mkv']), isFalse);
    });

    test('an unreachable engine answers no rather than throwing', () async {
      final result = await service(engine: _FakeEngine(throws: true))
          .isEpisodeCurrentlyDownloading(
            showName: 'The Bear',
            season: 2,
            episode: 4,
          );
      expect(result, isFalse);
    });
  });

  group('pickEpisodeTorrent', () {
    EztvTorrent? pick({
      List<EztvTorrent> eztv = const [],
      List<TorrentioStream> torrentio = const [],
      String? quality,
      int? maxSize,
      Set<String> exclude = const {},
    }) => AutoDownloadService.pickEpisodeTorrent(
      eztv: eztv,
      torrentio: torrentio,
      season: 1,
      episode: 5,
      preferredQuality: quality,
      maxSizeBytes: maxSize,
      excludeHashes: exclude,
    );

    test('a seeded release beats a dead one of better quality', () {
      // 720p with no seeds used to win on quality, and the stream never
      // started.
      final result = pick(
        eztv: [
          _eztv('dead', 'Show.S01E05.720p.mkv', seeds: 0),
          _eztv('alive', 'Show.S01E05.HDTV.mkv', seeds: 40),
        ],
        quality: '720p',
      );
      expect(result!.hash, 'alive');
    });

    test('when every EZTV release is dead, Torrentio is asked', () {
      final result = pick(
        eztv: [_eztv('dead', 'Show.S01E05.1080p.mkv', seeds: 0)],
        torrentio: [_stream('tio', '1080p', seeders: 25)],
      );
      expect(result!.hash, 'tio');
    });

    test('a dead release is still better than nothing', () {
      // A new release often lists 0 seeds until the indexer catches up.
      final result = pick(
        eztv: [_eztv('fresh', 'Show.S01E05.1080p.mkv', seeds: 0)],
        torrentio: [_stream('tio-dead', '720p', seeders: 0)],
      );
      expect(result!.hash, 'fresh');
    });

    test('the preferred quality wins among seeded releases', () {
      final result = pick(
        eztv: [
          _eztv('uhd', 'Show.S01E05.2160p.mkv', seeds: 50),
          _eztv('fhd', 'Show.S01E05.1080p.mkv', seeds: 10),
        ],
        quality: '1080P', // an older build's spelling
      );
      expect(result!.hash, 'fhd');
    });

    test('a download is not held to the streaming size cap', () {
      final eztv = [
        _eztv('big', 'Show.S01E05.1080p.mkv', seeds: 30, gb: 2.1),
        _eztv('small', 'Show.S01E05.720p.mkv', seeds: 30, gb: 0.8),
      ];
      expect(pick(eztv: eztv, quality: '1080p')!.hash, 'big');
      expect(
        pick(
          eztv: eztv,
          quality: '1080p',
          maxSize: AutoDownloadService.maxStreamingSizeBytes,
        )!.hash,
        'small',
        reason: 'streaming keeps the cap',
      );
    });

    test('never picks an excluded torrent again', () {
      final result = pick(
        eztv: [
          _eztv('failed', 'Show.S01E05.1080p.mkv', seeds: 90),
          _eztv('other', 'Show.S01E05.720p.mkv', seeds: 5),
        ],
        exclude: {'FAILED'},
      );
      expect(result!.hash, 'other');
    });

    test('Torrentio: one episode over a pack, seeded over dead', () {
      final result = pick(
        torrentio: [
          _stream(
            'pack',
            '1080p',
            seeders: 300,
            title: 'Show.S01',
            fileIdx: 4,
            filename: 'Show.S01E05.1080p.mkv',
          ),
          _stream('dead-single', '1080p', seeders: 0),
          _stream('single', '720p', seeders: 12),
        ],
      );
      expect(result!.hash, 'single');
    });

    test('a Torrentio pick keeps its file index', () {
      final result = pick(
        torrentio: [
          _stream(
            'pack',
            '1080p',
            seeders: 30,
            title: 'Show.S01.Complete.1080p',
            fileIdx: 4,
          ),
        ],
      );
      expect(result!.fileIdx, 4);
    });

    test('nothing at all is null', () {
      expect(pick(), isNull);
    });
  });

  group('findTorrentForEpisode', () {
    test('asks both indexers, and survives one failing', () async {
      final eztv = _FakeEztv(throws: true);
      final torrentio = _FakeTorrentio(
        streams: [_stream('tio', '1080p', seeders: 20)],
      );
      final result = await service(
        eztv: eztv,
        torrentio: torrentio,
      ).findTorrentForEpisode(imdbId: 'tt1', season: 1, episode: 5);

      expect(eztv.calls, 1);
      expect(torrentio.calls, 1);
      expect(result!.hash, 'tio');
    });
  });

  group('downloadNextEpisode', () {
    List<TorrentFile> pack({double done = 0}) => [
      for (var i = 0; i < 4; i++)
        TorrentFile(
          index: i,
          name: 'Pack/E0${i + 1}.mkv',
          size: 100,
          progress: i == 3 ? 1 : done,
          priority: 1,
          isSeed: false,
          availability: 1,
        ),
    ];

    test('waits for the file list, then fetches one episode only', () async {
      // The fixed two-second wait usually ended before qBittorrent had the
      // metadata, nothing was deselected, and the whole pack downloaded.
      final engine = _FakeEngine(filesAfter: 3, files: pack());
      final ok = await service(engine: engine).downloadNextEpisode(
        magnetLink: 'magnet:?xt=urn:btih:pack',
        infoHash: 'pack',
        fileIdx: 1,
      );

      expect(ok, isTrue);
      expect(engine.fileListCalls, greaterThanOrEqualTo(3));
      final skip = engine.priorityCalls.first;
      expect(skip.ids, [0, 2], reason: 'the finished extra is left alone');
      expect(skip.priority, 0);
      final keep = engine.priorityCalls.last;
      expect(keep.ids, [1]);
      expect(keep.priority, 7);
    });

    test('reports a pack whose file list never arrives', () async {
      final engine = _FakeEngine(filesAfter: 1 << 30, files: pack());
      final selected = await service(
        engine: engine,
      ).selectEpisodeFile('pack', 1);
      expect(selected, isFalse);
      expect(engine.priorityCalls, isEmpty);
    });

    test('reports an engine that refuses the selection', () async {
      final engine = _FakeEngine(files: pack(), priorityResult: false);
      expect(
        await service(engine: engine).selectEpisodeFile('pack', 1),
        isFalse,
      );
    });

    test('a refused add is a failure', () async {
      final engine = _FakeEngine(addResult: false);
      expect(
        await service(
          engine: engine,
        ).downloadNextEpisode(magnetLink: 'magnet:?xt=urn:btih:x'),
        isFalse,
      );
    });
  });

  group('engineTorrents', () {
    test('an unreachable engine is no answer, not an empty list', () async {
      // Both engines answer a failed list request with []; acting on that
      // would release every queued download.
      final engine = _FakeEngine(reachable: false);
      expect(await service(engine: engine).engineTorrents(), isNull);
    });

    test('a reachable engine with nothing in it is an empty list', () async {
      expect(await service().engineTorrents(), isEmpty);
    });
  });

  group('EpisodeTrackingInfo', () {
    test('round-trips through JSON', () {
      final info = EpisodeTrackingInfo(
        showId: 95396,
        imdbId: 'tt11280740',
        showName: 'Severance',
        season: 2,
        episode: 4,
        status: EpisodeDownloadStatus.downloading,
        quality: '1080p',
        torrentHash: 'abc123',
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
      final restored = EpisodeTrackingInfo.fromJson({
        'show_id': 1,
        'show_name': 'Severance',
        'season': 1,
        'episode': 1,
      });
      expect(restored.status, EpisodeDownloadStatus.notAired);
    });

    test('an older entry with retired fields still reads', () {
      final restored = EpisodeTrackingInfo.fromJson({
        'show_id': 1,
        'show_name': 'Severance',
        'season': 1,
        'episode': 1,
        'status': 4,
        'air_date': '2026-01-01',
        'magnet_link': 'magnet:?xt=urn:btih:x',
      });
      expect(restored.status, EpisodeDownloadStatus.downloaded);
    });

    test('an unknown status index is rejected, not mis-read', () {
      // `values[index]` threw a RangeError that reset every show's tracking;
      // now the one entry is rejected and the loader skips it.
      expect(
        () => EpisodeTrackingInfo.fromJson({
          'show_id': 1,
          'show_name': 'Severance',
          'season': 1,
          'episode': 1,
          'status': 99,
        }),
        throwsFormatException,
      );
    });
  });
}

EztvTorrent _eztv(
  String hash,
  String filename, {
  int seeds = 0,
  double gb = 0,
}) => EztvTorrent(
  id: hash.hashCode,
  hash: hash,
  filename: filename,
  magnetUrl: 'magnet:?xt=urn:btih:$hash',
  title: filename,
  seeds: seeds,
  sizeBytes: (gb * 1024 * 1024 * 1024).round(),
);

TorrentioStream _stream(
  String hash,
  String quality, {
  int seeders = 0,
  String title = 'Show.S01E05',
  int? fileIdx,
  String? filename,
}) => TorrentioStream(
  name: 'Torrentio\n$quality',
  title: '$title.$quality.WEB\n👤 $seeders 💾 1.2 GB ⚙️ Site',
  infoHash: hash,
  fileIdx: fileIdx,
  filename: filename,
);

Torrent _torrent(String name) => Torrent(
  hash: name.hashCode.toString(),
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

class _FakeTmdb extends TmdbApiService {
  _FakeTmdb({this.show, this.seasons = const {}, this.throws = false})
    : super(accessToken: 'test');

  final Show? show;
  final Map<int, List<Episode>> seasons;
  final bool throws;

  @override
  Future<Show> getShowDetails(int showId) async {
    if (throws) throw TmdbApiException('TMDB unreachable', isNetwork: true);
    return show ?? Show(id: showId, name: 'Unknown');
  }

  @override
  Future<List<Episode>> getSeasonEpisodes(int showId, int seasonNumber) async {
    if (throws) throw TmdbApiException('TMDB unreachable', isNetwork: true);
    final found = seasons[seasonNumber];
    if (found == null) {
      throw TmdbApiException('no such season', statusCode: 404);
    }
    return found;
  }
}

class _FakeEztv extends EztvApiService {
  _FakeEztv({this.throws = false}) : torrents = const [];

  final List<EztvTorrent> torrents;
  final bool throws;
  int calls = 0;

  @override
  Future<List<EztvTorrent>> getTorrentsForEpisode(
    String imdbId, {
    int? season,
    int? episode,
  }) async {
    calls++;
    if (throws) throw EztvApiException('blocked', isTimeout: true);
    return torrents;
  }
}

class _FakeTorrentio extends TorrentioApiService {
  _FakeTorrentio({this.streams = const []});

  final List<TorrentioStream> streams;
  int calls = 0;

  @override
  Future<TorrentioResponse> getSeriesStreams(
    String imdbId, {
    required int season,
    required int episode,
  }) async {
    calls++;
    return TorrentioResponse(streams: streams);
  }
}

class _FakeEngine extends QBittorrentApiService {
  _FakeEngine({
    this.torrents = const [],
    this.throws = false,
    this.reachable = true,
    this.addResult = true,
    this.files = const [],
    this.filesAfter = 0,
    this.priorityResult = true,
  });

  final List<Torrent> torrents;
  final bool throws;
  final bool reachable;
  final bool addResult;
  final List<TorrentFile> files;

  /// File-list requests answered empty before [files] (metadata arriving).
  final int filesAfter;
  final bool priorityResult;

  int fileListCalls = 0;
  final List<({List<int> ids, int priority})> priorityCalls = [];

  @override
  Future<bool> testConnection() async => reachable;

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
    if (throws) throw StateError('engine unreachable');
    return reachable ? torrents : const [];
  }

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    String? category,
    bool? paused,
    bool? skipChecking,
    bool? sequentialDownload,
    bool? firstLastPiecePrio,
  }) async => addResult;

  @override
  Future<List<TorrentFile>> getTorrentFiles(String hash) async {
    fileListCalls++;
    return fileListCalls > filesAfter ? files : const [];
  }

  @override
  Future<bool> setFilePriority(
    String hash,
    List<int> fileIds,
    int priority,
  ) async {
    priorityCalls.add((ids: fileIds, priority: priority));
    return priorityResult;
  }
}
