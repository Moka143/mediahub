import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_torrent_client/models/torrent.dart';
import 'package:flutter_torrent_client/utils/constants.dart';

Torrent _torrentWithState(String state) => Torrent.fromJson({
  'hash': 'deadbeef',
  'name': 'sample',
  'size': 1000,
  'progress': 1.0,
  'state': state,
});

void main() {
  group('Torrent.statusText — qBit 5.x state aliases', () {
    test('stoppedDL maps to "Paused" (same as pausedDL)', () {
      expect(_torrentWithState(TorrentState.stoppedDL).statusText, 'Paused');
      expect(
        _torrentWithState(TorrentState.pausedDL).statusText,
        _torrentWithState(TorrentState.stoppedDL).statusText,
      );
    });

    test('stoppedUP maps to "Paused (Seeding)" (same as pausedUP)', () {
      expect(
        _torrentWithState(TorrentState.stoppedUP).statusText,
        'Paused (Seeding)',
      );
      expect(
        _torrentWithState(TorrentState.pausedUP).statusText,
        _torrentWithState(TorrentState.stoppedUP).statusText,
      );
    });

    test('unrecognised state still falls back to "Unknown"', () {
      expect(_torrentWithState('madeUpFutureState').statusText, 'Unknown');
    });
  });
}
