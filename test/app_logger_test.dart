import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_torrent_client/services/app_logger.dart';

void main() {
  late Directory tmp;
  late File logFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mediahub_log_test');
    logFile = File('${tmp.path}/mediahub.log');
    await AppLog.resetForTest(file: logFile);
  });

  tearDown(() async {
    await AppLog.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('AppLog writing', () {
    test('appends a levelled line', () async {
      AppLog.e('[Test] boom');
      await AppLog.idle;

      expect(await logFile.readAsString(), contains('ERROR [Test] boom'));
    });

    test('labels every level distinctly', () async {
      AppLog.d('[Test] dbg');
      AppLog.i('[Test] inf');
      AppLog.w('[Test] wrn');
      AppLog.e('[Test] err');
      await AppLog.idle;

      final content = await logFile.readAsString();
      expect(content, contains('DEBUG [Test] dbg'));
      expect(content, contains('INFO  [Test] inf'));
      expect(content, contains('WARN  [Test] wrn'));
      expect(content, contains('ERROR [Test] err'));
    });

    test('preserves call order across unawaited writes', () async {
      for (var i = 0; i < 20; i++) {
        AppLog.d('[Test] line $i');
      }
      await AppLog.idle;

      final lines = (await logFile.readAsString())
          .trim()
          .split('\n')
          .where((l) => l.contains('[Test]'))
          .toList();

      expect(lines, hasLength(20));
      expect(lines.first, contains('line 0'));
      expect(lines.last, contains('line 19'));
    });

    test('exposes the active file path', () {
      expect(AppLog.filePath, logFile.path);
    });
  });

  group('AppLog rotation', () {
    test('keeps one previous generation instead of deleting history', () async {
      // The predecessor to this class deleted the log at the size cap, which
      // destroyed the breadcrumbs leading up to a late-session crash.
      AppLog.d('[Test] first ${'x' * AppLog.maxBytes}');
      await AppLog.idle;
      AppLog.d('[Test] second');
      await AppLog.idle;

      final rotated = File('${logFile.path}.1');
      expect(await rotated.exists(), isTrue);
      expect(await rotated.readAsString(), contains('first'));
      expect(await logFile.readAsString(), contains('second'));
      expect(await logFile.readAsString(), isNot(contains('first')));
    });

    test('a second rotation replaces the previous generation', () async {
      AppLog.d('[Test] gen1 ${'x' * AppLog.maxBytes}');
      await AppLog.idle;
      AppLog.d('[Test] gen2 ${'x' * AppLog.maxBytes}');
      await AppLog.idle;
      AppLog.d('[Test] gen3');
      await AppLog.idle;

      final rotated = File('${logFile.path}.1');
      expect(await rotated.readAsString(), contains('gen2'));
      expect(await rotated.readAsString(), isNot(contains('gen1')));
      expect(await logFile.readAsString(), contains('gen3'));
    });
  });

  group('AppLog resilience', () {
    test('writes are no-ops when no log file could be opened', () async {
      await AppLog.resetForTest();

      expect(() => AppLog.e('[Test] nowhere to go'), returnsNormally);
      await AppLog.idle;
      expect(AppLog.filePath, isNull);
    });

    test('an unwritable path does not throw into the caller', () async {
      // Point at a path whose parent does not exist.
      await AppLog.resetForTest(
        file: File('${tmp.path}/missing-dir/nested/mediahub.log'),
      );

      expect(() => AppLog.e('[Test] still fine'), returnsNormally);
      await AppLog.idle;
    });
  });
}
