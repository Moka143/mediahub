import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/models/local_media_file.dart';
import 'package:mediahub/services/local_media_scanner.dart';

/// The library scan must survive entries it cannot read.
///
/// `Directory.list` reports a folder it cannot open as a stream error and
/// then keeps going, but an error that reaches `await for` breaks the loop —
/// so a single unreadable folder used to discard every file found after it,
/// leaving a half-empty Library and one log line.
///
/// Windows hits this routinely and macOS almost never does, which is how it
/// survived: a download folder at a drive root always contains
/// `System Volume Information` and `$RECYCLE.BIN`, neither readable, and
/// OneDrive adds placeholders that fail to stat until they are hydrated.
///
/// The unreadable-directory case is reproduced here with POSIX permissions,
/// so it is skipped on Windows and when running as root.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mediahub_scan'));

  tearDown(() {
    // Restore any mode the test changed, or the cleanup cannot descend
    // either. `-R` walks it without needing to list the locked folder first.
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['-R', 'u+rwX', root.path]);
    }
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A file big enough for the scanner's minimum, created sparsely.
  void makeVideo(String relative) {
    final file = File('${root.path}${Platform.pathSeparator}$relative');
    file.parent.createSync(recursive: true);
    final raf = file.openSync(mode: FileMode.write);
    raf.truncateSync(2 * minPlayableBytes);
    raf.closeSync();
  }

  Directory makeDir(String relative) =>
      Directory('${root.path}${Platform.pathSeparator}$relative')
        ..createSync(recursive: true);

  test('finds videos across nested folders', () async {
    makeVideo('Severance.S02E04.1080p.mkv');
    makeVideo('The Bear/Season 03/The.Bear.S03E01.1080p.mkv');

    final found = await LocalMediaScanner(root.path).scanDirectory();
    expect(found.map((f) => f.fileName), hasLength(2));
  });

  test('an empty directory scans to nothing rather than throwing', () async {
    expect(await LocalMediaScanner(root.path).scanDirectory(), isEmpty);
  });

  test('a missing directory scans to nothing', () async {
    // The configured save path can point at a drive that is not mounted.
    final gone = '${root.path}${Platform.pathSeparator}not-there';
    expect(await LocalMediaScanner(gone).scanDirectory(), isEmpty);
  });

  test(
    'keeps scanning past a directory it cannot open',
    () async {
      // The regression. `zz-locked` sorts after `aa-`, so a scan that gave up
      // on the error would still return the first file and lose the last —
      // which is exactly what made this look like flaky indexing rather than
      // a bug.
      makeVideo('aa-first/First.S01E01.mkv');
      final locked = makeDir('zz-locked');
      File(
        '${locked.path}${Platform.pathSeparator}Hidden.S01E02.mkv',
      ).writeAsBytesSync(List.filled(16, 0));
      makeVideo('zz-visible/Last.S01E03.mkv');

      final chmod = Process.runSync('chmod', ['000', locked.path]);
      expect(chmod.exitCode, 0, reason: 'could not make the fixture');
      // Running as root ignores the mode bits entirely, and then there is
      // no unreadable folder to scan past.
      var enforced = false;
      try {
        Directory(locked.path).listSync();
      } on FileSystemException {
        enforced = true;
      }
      if (!enforced) {
        markTestSkipped('running with permission to read anything');
        return;
      }

      final found = await LocalMediaScanner(root.path).scanDirectory();
      final names = found.map((f) => f.fileName).toList();
      expect(names, contains('First.S01E01.mkv'));
      expect(
        names,
        contains('Last.S01E03.mkv'),
        reason: 'the walk must continue past the unreadable folder',
      );
    },
    skip: Platform.isWindows
        ? 'POSIX permissions are the reproduction here'
        : false,
  );
}
