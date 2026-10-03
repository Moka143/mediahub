import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/torrentio_stream.dart';
import 'package:mediahub/widgets/mediahub_torrent_drawer.dart';

TorrentioStream _source(
  String quality,
  int peers, {
  String hash = '',
  String size = '1.4 GB',
}) => TorrentioStream(
  name: 'Torrentio\n$quality',
  title: 'Show.S01E01.$quality.WEB-DL\n👤 $peers 💾 $size ⚙️ TPB',
  infoHash: hash.isEmpty ? '$quality-$peers' : hash,
);

void main() {
  group('bestSource', () {
    test('ranks across tiers, not the first row of the top tier', () {
      // The star used to land on the first 2160p row: a 3-peer source
      // marked best over an 800-peer 1080p one.
      final best = bestSource([
        _source('2160p', 3),
        _source('1080p', 800),
        _source('720p', 50),
      ]);
      expect(best?.quality, '1080p');
    });

    test('a well-shared higher quality still wins', () {
      final best = bestSource([_source('2160p', 400), _source('1080p', 120)]);
      expect(best?.quality, '2160p');
    });

    test('never picks a source nobody shares when another is alive', () {
      final best = bestSource([_source('2160p', 0), _source('720p', 2)]);
      expect(best?.quality, '720p');
    });

    test('is null for no sources', () {
      expect(bestSource(const []), isNull);
    });
  });

  testWidgets('the picker leads with Stream; a row click streams; Download '
      'is the second choice', (tester) async {
    final picks = <(String, bool)>[];
    final streams = [_source('1080p', 800), _source('720p', 40)];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => MediaHubTorrentDrawer.show(
                  context: context,
                  title: 'Silo',
                  subtitle: 'S01E01',
                  streams: streams,
                  onSelect: (s, isStreaming) =>
                      picks.add((s.infoHash, isStreaming)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('★ Best'), findsOneWidget);
    expect(find.text('Stream'), findsNWidgets(2));
    expect(find.text('Download'), findsNWidgets(2));
    // No more jargon: no CACHED badge, no "pack/single/multi", no "Seeded".
    expect(find.textContaining('CACHED'), findsNothing);
    expect(find.text('Seeded'), findsNothing);
    expect(find.text('single'), findsNothing);

    // Clicking the row body streams.
    await tester.tap(find.text('800 peers'));
    await tester.pumpAndSettle();
    expect(picks, [('1080p-800', true)]);

    // Reopen and download the other one.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download').last);
    await tester.pumpAndSettle();
    expect(picks.last, ('720p-40', false));
  });
}
