import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mediahub/app.dart';
import 'package:mediahub/design/app_theme.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/models/stream_request.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_action_result.dart';
import 'package:mediahub/models/torrentio_stream.dart';
import 'package:mediahub/providers/connection_provider.dart' as connection;
import 'package:mediahub/providers/navigation_provider.dart';
import 'package:mediahub/providers/streaming_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/screens/_details_playback_controller.dart';
import 'package:mediahub/services/streaming_service.dart';
import 'package:mediahub/services/torrent_engine.dart';
import 'package:mediahub/widgets/player/player_error_overlay.dart';

const _hash = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01';

final _stream = TorrentioStream(
  name: 'Torrentio\n1080p',
  title: 'Dune.Part.Two.2024.1080p.mkv',
  infoHash: _hash,
);

final _file = LocalMediaFile(
  path: '/library/Dune.Part.Two.2024.1080p.mkv',
  fileName: 'Dune.Part.Two.2024.1080p.mkv',
  sizeBytes: 4 << 30,
  modifiedDate: DateTime(2026),
  extension: 'mkv',
);

/// Sessions the test starts and finishes by hand.
class _FakeSessions extends StreamingSessionsNotifier {
  final List<Completer<StreamingSession?>> starts = [];
  final List<String> cancelled = [];

  @override
  StreamingSessionsState build() => const StreamingSessionsState();

  @override
  Future<StreamingSession?> startStreaming({
    required TorrentioStream stream,
    String? showImdbId,
    String? showName,
    String? movieImdbId,
    int? season,
    int? episode,
    String? episodeCode,
    String? savePath,
  }) {
    final start = Completer<StreamingSession?>();
    starts.add(start);
    return start.future;
  }

  /// Mirror a session update, as the real notifier does for the active one.
  void publish(StreamingSession session) {
    state = state.copyWith(
      sessions: {...state.sessions, session.id: session},
      activeSessionId: session.id,
    );
  }

  @override
  Future<void> cancelSession(String sessionId) async {
    cancelled.add(sessionId);
    state = state.copyWith(
      sessions: Map.of(state.sessions)..remove(sessionId),
      clearActive: true,
    );
  }
}

class _FakeTorrents extends TorrentListNotifier {
  _FakeTorrents([this.initial = const []]);

  final List<Torrent> initial;
  final List<String> deleted = [];

  @override
  TorrentListState build() => TorrentListState(torrents: initial);

  @override
  Future<TorrentActionResult> deleteTorrent(
    String hash, {
    bool deleteFiles = false,
  }) async {
    deleted.add('$hash files=$deleteFiles');
    return const TorrentActionResult.success();
  }
}

class _ConnectedNotifier extends connection.ConnectionNotifier {
  _ConnectedNotifier(this.status);

  final connection.ConnectionStatus status;

  @override
  connection.ConnectionState build() =>
      connection.ConnectionState(status: status);
}

class _FakeEngine implements TorrentEngine {
  final List<String> added = [];

  @override
  Future<bool> addTorrent({
    String? magnetLink,
    Object? torrentFile,
    String? savePath,
    String? category,
    bool? paused,
    bool? skipChecking,
    bool? sequentialDownload,
  }) async {
    added.add(magnetLink ?? '');
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host extends ConsumerStatefulWidget {
  const _Host();

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host>
    with DetailsPlaybackController<_Host> {
  int settled = 0;
  int anotherSource = 0;

  late final DetailsStreamTarget target = DetailsStreamTarget(
    label: '"Dune"',
    onSettled: () => settled++,
    onTryAnotherSource: () => anotherSource++,
    openPlayer: (file, session) => Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              Navigator.of(context).pop(PlayerExitReason.tryAnotherSource),
          child: Text('player ${file.fileName}'),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    disposePlaybackController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: () =>
              unawaited(startDetailsStream(stream: _stream, target: target)),
          child: const Text('stream'),
        ),
        TextButton(
          onPressed: () => unawaited(
            startDetailsDownload(
              stream: _stream,
              target: target,
              isStreaming: false,
            ),
          ),
          child: const Text('download'),
        ),
      ],
    ),
  );
}

StreamingSession _session(StreamingState state, {LocalMediaFile? file}) =>
    StreamingSession(
      id: 'session-1',
      request: StreamRequest.fromTorrentio(_stream),
      state: state,
      torrentHash: _hash,
      videoFile: file,
      streamUrl: file == null ? null : 'http://127.0.0.1:5000/stream/0',
    );

/// The streaming card on the details screens, and the picker's Download.
///
/// The card's ✕ only hid it: the torrent kept downloading and the player
/// pushed itself on top later anyway; its notifier was never disposed; and a
/// click during the torrent add was followed, once the add returned, by a
/// brand-new "Preparing…" card.
void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  late _FakeSessions sessions;
  late _FakeTorrents torrents;
  late _FakeEngine engine;

  Future<_HostState> pumpHost(
    WidgetTester tester, {
    List<Torrent> existing = const [],
    connection.ConnectionStatus status = connection.ConnectionStatus.connected,
  }) async {
    sessions = _FakeSessions();
    torrents = _FakeTorrents(existing);
    engine = _FakeEngine();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          streamingSessionsProvider.overrideWith(() => sessions),
          torrentListProvider.overrideWith(() => torrents),
          connection.connectionProvider.overrideWith(
            () => _ConnectedNotifier(status),
          ),
          connection.torrentEngineProvider.overrideWithValue(engine),
        ],
        child: MaterialApp(
          theme: buildDarkTheme(),
          navigatorKey: rootNavigatorKey,
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          home: const _Host(),
        ),
      ),
    );
    return tester.state<_HostState>(find.byType(_Host));
  }

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('Hide during the add: no second card, and the player opens', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    await tester.tap(find.text('stream'));
    await tester.pump();
    expect(find.text('Starting "Dune"'), findsOneWidget);

    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(find.text('Starting "Dune"'), findsNothing);
    expect(host.streamingOverlayData, isNull, reason: 'disposed, not leaked');

    // The add returns after the card was hidden.
    sessions.starts.single.complete(_session(StreamingState.addingTorrent));
    await tester.pumpAndSettle();
    expect(find.textContaining('Preparing'), findsNothing);
    expect(find.textContaining('Starting'), findsNothing);

    // Still preparing out of sight, so the player opens when it is ready.
    sessions.publish(_session(StreamingState.ready, file: _file));
    await tester.pumpAndSettle();
    expect(find.text('player ${_file.fileName}'), findsOneWidget);
    expect(sessions.cancelled, isEmpty);
    expect(host.settled, 1);

    await unmount(tester);
  });

  testWidgets('Cancel during the add stops the session once it exists', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    await tester.tap(find.text('stream'));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Starting "Dune"'), findsNothing);
    expect(host.settled, 1);

    sessions.starts.single.complete(_session(StreamingState.addingTorrent));
    await tester.pumpAndSettle();
    expect(sessions.cancelled, ['session-1']);
    expect(find.textContaining('Preparing'), findsNothing);

    // The stream added this torrent, so removing it is offered.
    expect(
      find.text(
        'Stopped streaming "Dune". Its download is still in Transfers.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Remove download'));
    await tester.pumpAndSettle();
    expect(torrents.deleted, ['${_hash.toLowerCase()} files=true']);

    await unmount(tester);
  });

  testWidgets('Cancel while buffering stops it, and nothing opens later', (
    tester,
  ) async {
    await pumpHost(tester);
    await tester.tap(find.text('stream'));
    await tester.pump();
    sessions.starts.single.complete(_session(StreamingState.addingTorrent));
    await tester.pump();
    sessions.publish(_session(StreamingState.buffering));
    await tester.pump();
    expect(find.text('Buffering "Dune"'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sessions.cancelled, ['session-1']);

    sessions.publish(_session(StreamingState.ready, file: _file));
    await tester.pumpAndSettle();
    expect(find.text('player ${_file.fileName}'), findsNothing);

    await unmount(tester);
  });

  testWidgets("a download that was already there isn't offered for removal", (
    tester,
  ) async {
    await pumpHost(
      tester,
      existing: [
        Torrent.fromJson({'hash': _hash.toLowerCase(), 'name': 'Dune'}),
      ],
    );
    await tester.tap(find.text('stream'));
    await tester.pump();
    sessions.starts.single.complete(_session(StreamingState.addingTorrent));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Stopped streaming "Dune".'), findsOneWidget);
    expect(find.text('Remove download'), findsNothing);

    await unmount(tester);
  });

  testWidgets('Try another source comes back to the details screen', (
    tester,
  ) async {
    final host = await pumpHost(tester);
    await tester.tap(find.text('stream'));
    await tester.pump();
    sessions.starts.single.complete(_session(StreamingState.addingTorrent));
    await tester.pump();
    sessions.publish(_session(StreamingState.ready, file: _file));
    await tester.pumpAndSettle();

    await tester.tap(find.text('player ${_file.fileName}'));
    await tester.pumpAndSettle();
    expect(host.anotherSource, 1);

    await unmount(tester);
  });

  group('startDetailsDownload', () {
    testWidgets('adds the torrent and offers the way to Transfers', (
      tester,
    ) async {
      final host = await pumpHost(tester);
      await tester.tap(find.text('download'));
      await tester.pumpAndSettle();

      expect(engine.added, [_stream.magnetUri]);
      expect(find.text('Downloading "Dune".'), findsOneWidget);
      expect(host.settled, 1);

      await tester.tap(find.text('View transfers'));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_Host)),
      );
      expect(container.read(currentTabIndexProvider), AppTab.transfers.index);

      await unmount(tester);
    });

    testWidgets('says so when the engine is not connected', (tester) async {
      final host = await pumpHost(
        tester,
        status: connection.ConnectionStatus.disconnected,
      );
      await tester.tap(find.text('download'));
      await tester.pump();

      expect(engine.added, isEmpty);
      expect(find.textContaining("isn't connected"), findsOneWidget);
      expect(host.settled, 1);

      await unmount(tester);
    });
  });
}
