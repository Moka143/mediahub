import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/app.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/stream_request.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/models/watch_progress.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/local_media_provider.dart';
import 'package:mediahub/providers/streaming_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/services/library_actions.dart';
import 'package:mediahub/services/streaming_service.dart';
import 'package:mediahub/widgets/media/local_playback.dart';
import 'package:path/path.dart' as p;

import 'support/transfers_fakes.dart';

const _movieHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _packHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// Resume for a title that was streamed rather than downloaded.
///
/// Closing the player ends its streaming session, but the torrent stays in
/// the engine, still fetching — so the file is neither finished nor being
/// streamed, and Resume on Home or a Continue Watching card used to
/// dead-end at "hasn't finished downloading yet". It now streams the file
/// again from that torrent, at the saved position, and keeps the message
/// for when the torrent is gone.
///
/// The completeness check stats the real file, and real file I/O does not
/// complete under the fake clock a `testWidgets` body runs in, so each
/// resume goes through `tester.runAsync`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  late Directory tmp;
  late _FakeSessions sessions;
  late List<_PlayerOpened> players;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mediahub_local_playback');
    sessions = _FakeSessions();
    players = [];
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ── Fixtures ───────────────────────────────────────────────────────────

  /// A sparse file of [bytes] under the temp root — full size, as the
  /// engine pre-allocates it, at no I/O cost.
  String makeFile(String relative, {int bytes = 2 * minPlayableBytes}) {
    final file = File(p.join(tmp.path, relative));
    file.parent.createSync(recursive: true);
    final raf = file.openSync(mode: FileMode.write);
    if (bytes > 0) raf.truncateSync(bytes);
    raf.closeSync();
    return file.path;
  }

  Torrent torrent(String hash, String name, {required String contentPath}) =>
      Torrent.fromJson({
        'hash': hash,
        'name': name,
        'state': 'downloading',
        'progress': 0.3,
        'save_path': tmp.path,
        'content_path': contentPath,
      });

  TorrentFile entry(
    int index,
    String name, {
    double progress = 0.3,
    int priority = 1,
  }) => TorrentFile(
    index: index,
    name: name,
    size: 2 * minPlayableBytes,
    progress: progress,
    priority: priority,
    isSeed: false,
    availability: 1,
  );

  WatchProgress progressFor(
    String path, {
    Duration position = const Duration(minutes: 42),
    String? showName,
    int? season,
    int? episode,
  }) => WatchProgress(
    fileHash: WatchProgress.generateHash(path),
    filePath: path,
    showName: showName,
    seasonNumber: season,
    episodeNumber: episode,
    episodeCode: season != null && episode != null
        ? 'S${season.toString().padLeft(2, '0')}'
              'E${episode.toString().padLeft(2, '0')}'
        : null,
    position: position,
    duration: const Duration(hours: 2),
    lastWatched: DateTime(2026, 10),
  );

  /// A partially streamed movie: a one-file torrent still in the engine.
  ({String path, Torrent torrent, List<TorrentFile> files}) movie() {
    const name = 'Dune.Part.Two.2024.1080p.mkv';
    final path = makeFile(name);
    return (
      path: path,
      torrent: torrent(_movieHash, name, contentPath: path),
      files: [entry(0, name)],
    );
  }

  /// A partially streamed episode out of a season pack: E01 finished, E02
  /// half there, E03 deselected by the stream that added the pack.
  ({String path, Torrent torrent, List<TorrentFile> files}) episode() {
    const folder = 'Severance.S02.1080p.WEB-DL';
    final path = makeFile('$folder/Severance.S02E02.1080p.mkv');
    return (
      path: path,
      torrent: torrent(
        _packHash,
        folder,
        contentPath: p.join(tmp.path, folder),
      ),
      files: [
        entry(0, '$folder/Severance.S02E01.1080p.mkv', progress: 1),
        entry(1, '$folder/Severance.S02E02.1080p.mkv', progress: 0.4),
        entry(
          2,
          '$folder/Severance.S02E03.1080p.mkv',
          progress: 0,
          priority: 0,
        ),
      ],
    );
  }

  // ── Harness ────────────────────────────────────────────────────────────

  late BuildContext hostContext;
  late WidgetRef hostRef;

  Future<void> pumpHost(
    WidgetTester tester, {
    List<Torrent> torrents = const [],
    List<TorrentFile> files = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamingSessionsProvider.overrideWith(() => sessions),
          torrentListProvider.overrideWith(() => FakeTorrentList(torrents)),
          torrentEngineProvider.overrideWithValue(FakeEngine(files: files)),
          localMediaFilesProvider.overrideWith(
            (ref) async => <LocalMediaFile>[],
          ),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          navigatorKey: rootNavigatorKey,
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                hostContext = context;
                hostRef = ref;
                return const Text('home');
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Press Resume on [progress], the way Home and Continue Watching do.
  Future<void> resume(WidgetTester tester, WatchProgress progress) async {
    await tester.runAsync(
      () => resumeProgress(
        hostContext,
        hostRef,
        progress,
        openPlayer: _fakePlayer(players),
      ),
    );
    await tester.pump();
  }

  /// What the engine reports once the head of [path] is down.
  StreamingSession ready(String path) => sessions.current.copyWith(
    state: StreamingState.ready,
    bufferProgress: 0.42,
    videoFile: LocalMediaFile.fromProgress(progressFor(path)),
    streamUrl: 'http://127.0.0.1:5000/stream/0',
  );

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  // ── Torrent still in the engine, file incomplete ──────────────────────

  group('torrent present and incomplete', () {
    testWidgets('a movie streams again and opens at the saved position', (
      tester,
    ) async {
      final m = movie();
      await pumpHost(tester, torrents: [m.torrent], files: m.files);
      final progress = progressFor(m.path);

      await resume(tester, progress);
      expect(find.text('Resuming "Dune Part Two"'), findsOneWidget);
      expect(find.textContaining("hasn't finished"), findsNothing);

      final request = sessions.requests.single;
      expect(request.request.infoHash, _movieHash);
      expect(request.request.magnetUri, startsWith('magnet:?xt=urn:btih:'));
      expect(request.request.magnetUri, contains(_movieHash));
      expect(request.request.isSingleFile, isTrue);

      sessions.publish(
        sessions.current.copyWith(
          state: StreamingState.buffering,
          bufferProgress: 0.31,
        ),
      );
      await tester.pump();
      expect(find.text('Buffering "Dune Part Two"'), findsOneWidget);

      sessions.publish(ready(m.path));
      await tester.pumpAndSettle();
      expect(find.textContaining('Dune Part Two'), findsNothing);

      final opened = players.single;
      expect(opened.file.path, m.path);
      expect(opened.startPosition, const Duration(minutes: 42));
      expect(opened.session?.id, 'session-1');
      expect(opened.session?.streamUrl, isNotNull, reason: 'not the zeros');
      expect(
        sessions.state.activeSessionId,
        isNull,
        reason: "the app shell's safety net must not push a second player",
      );

      // A later update must not open the player again.
      sessions.publish(ready(m.path).copyWith(state: StreamingState.playing));
      await tester.pumpAndSettle();
      expect(players, hasLength(1));

      await unmount(tester);
    });

    testWidgets('an episode streams its own file out of the pack', (
      tester,
    ) async {
      final e = episode();
      await pumpHost(tester, torrents: [e.torrent], files: e.files);
      final progress = progressFor(
        e.path,
        position: const Duration(minutes: 17),
        showName: 'Severance',
        season: 2,
        episode: 2,
      );

      await resume(tester, progress);
      expect(find.text('Resuming "Severance S02E02"'), findsOneWidget);

      final start = sessions.requests.single;
      expect(start.request.infoHash, _packHash);
      expect(start.request.fileIdx, 1);
      expect(start.request.isSingleFile, isFalse);
      expect(
        start.request.isSeasonPack,
        isTrue,
        reason: 'so the session re-selects the episode if it was dropped',
      );
      expect((start.season, start.episode), (2, 2));
      expect(start.showName, 'Severance');

      sessions.publish(ready(e.path));
      await tester.pumpAndSettle();

      final opened = players.single;
      expect(opened.file.path, e.path);
      expect(opened.file.showName, 'Severance');
      expect(opened.startPosition, const Duration(minutes: 17));
      expect(opened.session?.id, 'session-1');

      await unmount(tester);
    });

    testWidgets('Cancel stops the stream, and nothing opens later', (
      tester,
    ) async {
      final m = movie();
      await pumpHost(tester, torrents: [m.torrent], files: m.files);

      await resume(tester, progressFor(m.path));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(sessions.cancelled, ['session-1']);
      expect(find.text('Resuming "Dune Part Two"'), findsNothing);
      expect(find.text('Stopped streaming "Dune Part Two".'), findsOneWidget);

      sessions.publish(ready(m.path));
      await tester.pumpAndSettle();
      expect(players, isEmpty);

      await unmount(tester);
    });

    testWidgets('a newer stream supersedes a hidden resume', (tester) async {
      // The sessions notifier follows only the active session, so a resume
      // left preparing out of sight would never hear of `ready` once another
      // stream starts — and would hold its session open for good.
      final m = movie();
      await pumpHost(tester, torrents: [m.torrent], files: m.files);

      await resume(tester, progressFor(m.path));
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(find.text('Resuming "Dune Part Two"'), findsNothing);
      expect(sessions.cancelled, isEmpty, reason: 'Hide keeps preparing');

      sessions.startOther();
      await tester.pumpAndSettle();
      expect(sessions.cancelled, ['session-1']);
      expect(find.textContaining('Stopped streaming'), findsNothing);
      expect(sessions.state.activeSessionId, 'other');

      sessions.publish(ready(m.path));
      await tester.pumpAndSettle();
      expect(players, isEmpty);

      await unmount(tester);
    });

    testWidgets('a stream that fails says why and opens nothing', (
      tester,
    ) async {
      final m = movie();
      await pumpHost(tester, torrents: [m.torrent], files: m.files);

      await resume(tester, progressFor(m.path));
      sessions.publish(
        sessions.current.copyWith(
          state: StreamingState.error,
          errorMessage: 'This download was removed from Transfers.',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Resuming "Dune Part Two"'), findsNothing);
      expect(find.textContaining("Couldn't stream"), findsOneWidget);
      expect(players, isEmpty);

      await unmount(tester);
    });

    testWidgets('a finished file still plays straight from disk', (
      tester,
    ) async {
      final m = movie();
      await pumpHost(
        tester,
        torrents: [m.torrent],
        files: [entry(0, 'Dune.Part.Two.2024.1080p.mkv', progress: 1)],
      );

      await resume(tester, progressFor(m.path));
      await tester.pumpAndSettle();

      expect(sessions.requests, isEmpty);
      expect(players.single.session, isNull);
      expect(players.single.startPosition, const Duration(minutes: 42));

      await unmount(tester);
    });
  });

  // ── Torrent gone ───────────────────────────────────────────────────────

  group('torrent gone', () {
    testWidgets("an unfinished file left behind says it hasn't finished", (
      tester,
    ) async {
      // Removed in Transfers, file kept — but only a sliver of it was ever
      // written, so there is nothing to play and nothing to stream from.
      final path = makeFile('Dune.Part.Two.2024.1080p.mkv', bytes: 4096);
      await pumpHost(tester);

      await resume(tester, progressFor(path));
      await tester.pump();

      expect(
        find.text(
          '"Dune.Part.Two.2024.1080p.mkv" hasn\'t finished downloading '
          'yet.',
        ),
        findsOneWidget,
      );
      expect(find.text('Open Transfers'), findsOneWidget);
      expect(sessions.requests, isEmpty);
      expect(players, isEmpty);

      await unmount(tester);
    });

    testWidgets('a file removed with its torrent says it is gone', (
      tester,
    ) async {
      final path = p.join(tmp.path, 'Dune.Part.Two.2024.1080p.mkv');
      await pumpHost(tester);

      await resume(tester, progressFor(path));
      await tester.pump();

      expect(
        find.text('"Dune.Part.Two.2024.1080p.mkv" isn\'t on disk any more.'),
        findsOneWidget,
      );
      expect(sessions.requests, isEmpty);
      expect(players, isEmpty);

      await unmount(tester);
    });
  });

  // ── The request itself ─────────────────────────────────────────────────

  group('streamRequestForTorrentFile', () {
    test('a movie with a sample is not a pack, but is picked by index', () {
      final t = torrent(_movieHash, 'Dune.Part.Two', contentPath: tmp.path);
      final files = [
        entry(
          0,
          'Dune.Part.Two/Sample/sample.mkv',
        ).withSize(minPlayableBytes ~/ 2),
        entry(1, 'Dune.Part.Two/Dune.Part.Two.2024.1080p.mkv'),
        entry(2, 'Dune.Part.Two/Dune.Part.Two.srt'),
      ];
      final request = streamRequestForTorrentFile(
        TorrentFileMatch(torrent: t, entry: files[1], files: files),
      );
      expect(request.fileIdx, 1);
      expect(request.filename, 'Dune.Part.Two.2024.1080p.mkv');
      expect(request.isSingleFile, isFalse);
      expect(request.isSeasonPack, isFalse);
      expect(request.magnetUri, contains('dn=Dune.Part.Two'));
    });
  });
}

extension on TorrentFile {
  TorrentFile withSize(int size) => TorrentFile(
    index: index,
    name: name,
    size: size,
    progress: progress,
    priority: priority,
    isSeed: isSeed,
    availability: availability,
  );
}

/// One push of the player page.
typedef _PlayerOpened = ({
  LocalMediaFile file,
  StreamingSession? session,
  Duration? startPosition,
});

/// A player page that records what it was opened with — the real one needs
/// mpv.
PlayerPageBuilder _fakePlayer(List<_PlayerOpened> opened) =>
    ({
      Key? key,
      required LocalMediaFile file,
      StreamingSession? session,
      String? showImdbId,
      String? movieImdbId,
      Duration? startPosition,
    }) {
      opened.add((file: file, session: session, startPosition: startPosition));
      return Scaffold(body: Text('player ${file.fileName}'));
    };

/// One call to [StreamingSessionsNotifier.startStreamingRequest].
typedef _Start = ({
  StreamRequest request,
  String? showName,
  int? season,
  int? episode,
});

/// Sessions the test moves through their states by hand.
class _FakeSessions extends StreamingSessionsNotifier {
  final List<_Start> requests = [];
  final List<String> cancelled = [];

  /// The session as it was last started or published — still there once
  /// it has been cancelled, to send it a late update.
  late StreamingSession current;

  @override
  StreamingSessionsState build() => const StreamingSessionsState();

  @override
  Future<StreamingSession?> startStreamingRequest({
    required StreamRequest request,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
    bool makeActive = true,
    bool allowSlowBuffer = false,
  }) async {
    requests.add((
      request: request,
      showName: showName,
      season: season,
      episode: episode,
    ));
    final session = StreamingSession(
      id: 'session-1',
      request: request,
      showName: showName,
      season: season,
      episode: episode,
      episodeCode: episodeCode,
      state: StreamingState.addingTorrent,
      torrentHash: request.infoHash,
    );
    current = session;
    state = state.copyWith(
      sessions: {...state.sessions, session.id: session},
      activeSessionId: makeActive ? session.id : null,
    );
    return session;
  }

  /// Mirror a session update, as the real notifier does for the active one.
  void publish(StreamingSession session) {
    current = session;
    state = state.copyWith(sessions: {...state.sessions, session.id: session});
  }

  /// Another screen starts a stream of its own, which becomes the active
  /// session.
  void startOther() {
    final other = StreamingSession(
      id: 'other',
      request: current.request,
      state: StreamingState.addingTorrent,
    );
    state = state.copyWith(
      sessions: {...state.sessions, other.id: other},
      activeSessionId: other.id,
    );
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    cancelled.add(sessionId);
    state = state.copyWith(
      sessions: Map.of(state.sessions)..remove(sessionId),
      clearActive: state.activeSessionId == sessionId,
    );
  }
}
