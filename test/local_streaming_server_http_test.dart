import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/services/local_streaming_server.dart';
import 'package:mediahub/services/torrent_engine.dart';

const _mib = 1024 * 1024;

/// A downloader engine that reports a two-file torrent: an earlier file of
/// 1.5 MiB, then the 3 MiB episode being streamed — which therefore starts
/// half way into piece 1 of a 1 MiB-piece torrent.
class _PackEngine extends TorrentEngine {
  _PackEngine(this.pieceStates);

  final List<int> pieceStates;

  @override
  String get baseUrl => 'http://fake';

  @override
  Future<bool> login() async => true;

  @override
  Future<bool> testConnection() async => true;

  @override
  Future<String?> getVersion() async => null;

  @override
  Future<List<Torrent>?> tryGetTorrents({List<String>? hashes}) async =>
      const [];

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async => [
    TorrentFile(
      index: 0,
      name: 'Pack/E01.mkv',
      size: 3 * _mib ~/ 2,
      progress: 1,
      priority: 1,
      isSeed: false,
      availability: 0,
    ),
    TorrentFile(
      index: 1,
      name: 'Pack/E02.mkv',
      size: 3 * _mib,
      progress: 0.5,
      priority: 1,
      isSeed: false,
      availability: 0,
    ),
  ];

  @override
  Future<int> getPieceSize(String hash) async => _mib;

  @override
  Future<List<int>?> getPieceStates(String hash) async => pieceStates;

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    File? torrentFile,
    String? savePath,
    bool? paused,
    bool? sequentialDownload,
  }) async => true;

  @override
  Future<bool> pauseTorrents(List<String> hashes) async => true;

  @override
  Future<bool> resumeTorrents(List<String> hashes) async => true;

  @override
  Future<bool> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async => true;

  @override
  Future<bool> setFilePriority(String h, List<int> ids, int p) async => true;

  @override
  void dispose() {}
}

Future<({int status, String? contentRange, List<int> body})> _get(
  String url, {
  required String range,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, range);
    final HttpClientResponse response;
    try {
      response = await request.close();
    } on HttpException {
      // Closed before any header: nothing was served at all.
      return (status: 0, contentRange: null, body: const <int>[]);
    }
    final body = <int>[];
    try {
      await for (final chunk in response) {
        body.addAll(chunk);
      }
    } on HttpException {
      // A response cut short by the server; what arrived is the answer.
    }
    return (
      status: response.statusCode,
      contentRange: response.headers.value(HttpHeaders.contentRangeHeader),
      body: body,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tmp;
  late File episode;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mediahub_proxy');
    episode = File('${tmp.path}/E02.mkv');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('serves only the bytes whose pieces are really down', () async {
    // The episode occupies torrent bytes 1.5–4.5 MiB. Pieces 0–2 are done,
    // so its first 1.5 MiB are on disk and the rest is pre-allocated zeros.
    // Assuming the file started on a piece boundary, the old maths counted
    // pieces 1 and 2 as its first 2 MiB and served half a megabyte of zeros.
    await episode.writeAsBytes([
      0x1A, 0x45, 0xDF, 0xA3, // EBML
      ...List<int>.filled(3 * _mib ~/ 2 - 4, 0x01),
      ...List<int>.filled(3 * _mib ~/ 2, 0x00),
    ]);
    final server = LocalStreamingServer(
      engine: _PackEngine([2, 2, 2, 0, 0]),
      filePath: episode.path,
      torrentHash: 'hash',
      fileIndex: 1,
      openPrefixWait: const Duration(milliseconds: 200),
    );
    await server.start();
    addTearDown(server.stop);

    final response = await _get(server.url, range: 'bytes=0-');

    expect(response.status, HttpStatus.partialContent);
    expect(response.contentRange, 'bytes 0-${3 * _mib ~/ 2 - 1}/${3 * _mib}');
    expect(response.body, hasLength(3 * _mib ~/ 2));
    expect(
      response.body.skip(4).every((b) => b == 0x01),
      isTrue,
      reason: 'not one byte of the zero-filled region',
    );
  });

  test('answers 503 rather than promising bytes that are not there', () async {
    await episode.writeAsBytes(List<int>.filled(3 * _mib, 0));
    final server = LocalStreamingServer(
      engine: _PackEngine([2, 0, 0, 0, 0]),
      filePath: episode.path,
      torrentHash: 'hash',
      fileIndex: 1,
      openPrefixWait: const Duration(milliseconds: 200),
    );
    await server.start();
    addTearDown(server.stop);

    // Piece 1 — shared with the end of E01 — is missing, so not even the
    // episode's first byte is down.
    final response = await _get(server.url, range: 'bytes=0-');
    expect(response.status, HttpStatus.serviceUnavailable);
  });

  test('gives up on a start that keeps reading as zeros', () async {
    // The piece map says the start is down, but the disk disagrees. More
    // download progress does not fix that, so the wait is bounded — this
    // branch used to re-read byte 0 every 400 ms for ever.
    await episode.writeAsBytes(List<int>.filled(3 * _mib, 0));
    final server = LocalStreamingServer(
      engine: _PackEngine([2, 2, 2, 2, 2]),
      filePath: episode.path,
      torrentHash: 'hash',
      fileIndex: 1,
      headerWaitLimit: const Duration(milliseconds: 300),
    );
    await server.start();
    addTearDown(server.stop);

    final response = await _get(
      server.url,
      range: 'bytes=0-1023',
    ).timeout(const Duration(seconds: 5));
    expect(response.status, HttpStatus.serviceUnavailable);
    expect(response.body, isEmpty, reason: 'not a byte of the zeros');
  });
}
