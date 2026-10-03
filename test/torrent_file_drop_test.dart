import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/widgets/common/torrent_file_drop.dart';

void main() {
  test('only .torrent files are kept, whatever the case', () {
    expect(
      torrentFilesIn(['/a/Show.TORRENT', '/a/notes.txt', r'C:\x\b.torrent']),
      ['/a/Show.TORRENT', r'C:\x\b.torrent'],
    );
  });

  testWidgets('a drop from the runner reaches the listener', (tester) async {
    final received = <List<String>>[];
    await tester.pumpWidget(
      TorrentFileDropListener(
        onTorrentFiles: received.add,
        child: const SizedBox(),
      ),
    );

    Future<void> drop(List<String> paths) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        torrentFileDropChannel.name,
        torrentFileDropChannel.codec.encodeMethodCall(
          MethodCall('filesDropped', paths),
        ),
        (_) {},
      );
    }

    await drop(['/downloads/a.torrent', '/downloads/movie.mkv']);
    // Nothing worth opening: the listener stays quiet.
    await drop(['/downloads/movie.mkv']);

    expect(received, [
      ['/downloads/a.torrent'],
    ]);
  });

  testWidgets('the handler is released with the widget', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      TorrentFileDropListener(
        onTorrentFiles: (_) => calls++,
        child: const SizedBox(),
      ),
    );
    await tester.pumpWidget(const SizedBox());

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      torrentFileDropChannel.name,
      torrentFileDropChannel.codec.encodeMethodCall(
        const MethodCall('filesDropped', ['/a.torrent']),
      ),
      (_) {},
    );
    expect(calls, 0);
  });
}
