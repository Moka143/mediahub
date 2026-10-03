import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/main.dart';
import 'package:mediahub/services/app_logger.dart';

void main() {
  late Directory tmp;
  late File logFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mediahub_uncaught');
    logFile = File('${tmp.path}/mediahub.log');
    await AppLog.resetForTest(file: logFile);
  });

  tearDown(() async {
    await AppLog.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('while bootstrapping, an uncaught error is fatal and says so', () async {
    // A throw before runApp() leaves a process with no window; exiting with
    // the reason on disk is better than a zombie that "did nothing".
    final exits = <int>[];
    await reportUncaughtError(
      StateError('no prefs'),
      StackTrace.current,
      bootstrapping: true,
      exitProcess: exits.add,
    );

    expect(exits, [1]);
    expect(
      await logFile.readAsString(),
      contains('[Startup] FATAL during startup: Bad state: no prefs'),
    );
  });

  test(
    'once the app is running, it is logged and the app carries on',
    () async {
      // This used to exit for the app's whole lifetime — labelled a startup
      // failure — so any stray async error made the app silently vanish.
      final exits = <int>[];
      await reportUncaughtError(
        StateError('ref used after dispose'),
        StackTrace.current,
        bootstrapping: false,
        exitProcess: exits.add,
      );
      await AppLog.idle;

      expect(exits, isEmpty);
      final log = await logFile.readAsString();
      expect(log, contains('[Uncaught] Bad state: ref used after dispose'));
      expect(log, isNot(contains('FATAL')));
    },
  );
}
