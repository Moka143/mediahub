import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/peer.dart';
import 'package:mediahub/models/torrent.dart';
import 'package:mediahub/models/torrent_action_result.dart';
import 'package:mediahub/models/torrent_file.dart';
import 'package:mediahub/models/tracker.dart';
import 'package:mediahub/providers/connection_provider.dart';
import 'package:mediahub/providers/torrent_provider.dart';
import 'package:mediahub/services/torrent_engine.dart';
import 'package:mediahub/utils/constants.dart';

/// Test doubles shared by the Transfers widget tests.
///
/// The engine is a [Fake]: only what the Transfers UI calls is implemented,
/// so the double does not have to track every member of the engine
/// interface — anything else throws if it is ever reached.

/// A torrent with only the fields a test cares about.
Torrent testTorrent({
  String hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String name = 'Some.Show.S01E01.1080p.WEB-DL.mkv',
  String state = TorrentState.downloading,
  double progress = 0.42,
  int size = 1000000000,
  int dlspeed = 0,
  int upspeed = 0,
  int eta = 600,
  int numSeeds = 0,
  int numLeeches = 0,
  int addedOn = 0,
  int lastActivity = 0,
  int pieceSize = 0,
  int piecesNum = 0,
  int piecesHave = 0,
}) {
  return Torrent.fromJson({
    'hash': hash,
    'name': name,
    'state': state,
    'progress': progress,
    'size': size,
    'amount_left': (size * (1 - progress)).round(),
    'dlspeed': dlspeed,
    'upspeed': upspeed,
    'eta': eta,
    'num_seeds': numSeeds,
    'num_leechs': numLeeches,
    'added_on': addedOn,
    'last_activity': lastActivity,
    'piece_size': pieceSize,
    'pieces_num': piecesNum,
    'pieces_have': piecesHave,
  });
}

TorrentFile testFile(int index, String name, {int priority = 1}) =>
    TorrentFile.fromJson({
      'name': name,
      'size': 100 * 1024 * 1024,
      'progress': 0.5,
      'priority': priority,
    }, index);

class FakeEngine extends Fake implements TorrentEngine {
  FakeEngine({
    this.capabilities = const EngineCapabilities(),
    this.files = const [],
    this.priorityResult = true,
  });

  @override
  final EngineCapabilities capabilities;

  List<TorrentFile> files;
  bool priorityResult;
  final priorityCalls = <({List<int> ids, int priority})>[];

  @override
  Future<List<TorrentFile>> getTorrentFiles(String hash) async => files;

  @override
  Future<List<TorrentFile>?> tryGetTorrentFiles(String hash) async => files;

  @override
  Future<List<Peer>> getTorrentPeers(String hash) async => const [];

  @override
  Future<List<Tracker>> getTorrentTrackers(String hash) async => const [];

  @override
  Future<bool> setFilePriority(
    String hash,
    List<int> fileIds,
    int priority,
  ) async {
    priorityCalls.add((ids: fileIds, priority: priority));
    return priorityResult;
  }

  @override
  void dispose() {}
}

/// The built-in engine's capabilities, as far as the UI asks.
/// What the built-in engine declares — see `RqbitEngine.capabilities`.
const builtinCapabilities = EngineCapabilities(
  trackers: false,
  deltaSync: false,
  liveSpeedLimits: false,
  pieceLevelControl: false,
  maintenanceActions: false,
  rankedFilePriorities: false,
  seedsAndPeersSplit: false,
  peerDetails: false,
);

class FakeConnection extends ConnectionNotifier {
  FakeConnection(this._initial);

  final ConnectionState _initial;

  @override
  ConnectionState build() => _initial;
}

class FakeTorrentList extends TorrentListNotifier {
  FakeTorrentList([this._initial = const []]);

  final List<Torrent> _initial;
  final deleteCalls = <List<String>>[];
  final addedLinks = <String>[];
  final addedFiles = <String>[];
  TorrentActionResult deleteResult = const TorrentActionResult.success();

  /// When set, adds wait for it — to look at the dialog mid-add.
  Completer<TorrentActionResult>? addGate;
  TorrentActionResult addResult = const TorrentActionResult.success();

  @override
  TorrentListState build() => TorrentListState(torrents: _initial);

  @override
  Future<void> refresh({bool fullUpdate = false}) async {}

  @override
  Future<TorrentActionResult> deleteTorrents(
    List<String> hashes, {
    bool deleteFiles = false,
  }) async {
    deleteCalls.add(hashes);
    if (deleteResult.success) {
      state = TorrentListState(
        torrents: [
          for (final torrent in state.torrents)
            if (!hashes.contains(torrent.hash)) torrent,
        ],
      );
    }
    return deleteResult;
  }

  @override
  Future<TorrentActionResult> addMagnet(
    String magnetLink, {
    String? savePath,
    bool startNow = true,
  }) {
    addedLinks.add(magnetLink);
    return addGate?.future ?? Future.value(addResult);
  }

  @override
  Future<TorrentActionResult> addTorrentFile(
    File file, {
    String? savePath,
    bool startNow = true,
  }) {
    addedFiles.add(file.path);
    return addGate?.future ?? Future.value(addResult);
  }
}

/// Records which routes were popped, to tell a closed dialog from a closed
/// page.
class PopRecorder extends NavigatorObserver {
  final popped = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      popped.add(route);
}

/// [home] in an app with [overrides] — the scope is part of the tree, so it
/// (and every provider's timers) is torn down with it.
Widget testApp(
  Widget home, {
  List<Override> overrides = const [],
  List<NavigatorObserver> observers = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      navigatorObservers: observers,
      home: Scaffold(body: home),
    ),
  );
}
