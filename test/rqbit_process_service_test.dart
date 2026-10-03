import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/engine_pid_file.dart';
import 'package:mediahub/services/rqbit_process_service.dart';
import 'package:mediahub/services/torrent_engine_process.dart';
import 'package:path/path.dart' as p;

void main() {
  List<String> args({
    String host = '127.0.0.1',
    int port = 3030,
    String downloadPath = '/downloads',
    String persistencePath = '/state/engine',
    int downloadLimitBytes = 0,
    int uploadLimitBytes = 0,
  }) => RqbitProcessService.buildArguments(
    host: host,
    port: port,
    downloadPath: downloadPath,
    persistencePath: persistencePath,
    downloadLimitBytes: downloadLimitBytes,
    uploadLimitBytes: uploadLimitBytes,
  );

  group('buildArguments', () {
    test('puts global flags before the subcommand', () {
      // clap will not accept a global option after `server`, and the failure
      // is a process that exits immediately — which surfaces here as "the
      // engine never became ready", with nothing pointing at the cause.
      final a = args();
      expect(
        a.indexOf('--http-api-listen-addr'),
        lessThan(a.indexOf('server')),
      );
      expect(
        a.indexOf('--disable-upnp-port-forward'),
        lessThan(a.indexOf('server')),
      );
    });

    test('binds the API to the given host and port', () {
      final a = args(host: '127.0.0.1', port: 9999);
      expect(a[a.indexOf('--http-api-listen-addr') + 1], '127.0.0.1:9999');
    });

    test('the subcommand is `server start`', () {
      final a = args();
      expect(a[a.indexOf('server') + 1], 'start');
    });

    test('the download folder is the trailing positional', () {
      expect(args(downloadPath: '/movies').last, '/movies');
    });

    test('session state goes where we put it, not rqbit\'s OS default', () {
      final a = args(persistencePath: '/state/engine');
      expect(a[a.indexOf('--persistence-location') + 1], '/state/engine');
      expect(
        a.indexOf('--persistence-location'),
        greaterThan(a.indexOf('start')),
        reason: 'it is a `server start` option, not a global one',
      );
    });

    test('no rate-limit flags when the limits are unset', () {
      // rqbit takes a NonZeroU32, so passing 0 is an argument error rather
      // than "unlimited".
      final a = args();
      expect(a, isNot(contains('--ratelimit-download')));
      expect(a, isNot(contains('--ratelimit-upload')));
    });

    test('rate limits are passed in bytes per second when set', () {
      final a = args(downloadLimitBytes: 1048576, uploadLimitBytes: 524288);
      expect(a[a.indexOf('--ratelimit-download') + 1], '1048576');
      expect(a[a.indexOf('--ratelimit-upload') + 1], '524288');
      expect(a.indexOf('--ratelimit-download'), lessThan(a.indexOf('server')));
    });

    test('does not pass --fastresume', () {
      // Deliberate: it skips checksumming on restart, and rqbit still marks it
      // experimental. A wrong resume shows up as corrupt video, not an error.
      expect(args(), isNot(contains('--fastresume')));
    });
  });

  _reclaimTests();
}

/// A process table the test controls: which PIDs are running what, and every
/// signal sent.
class _FakeProbe implements EngineProcessProbe {
  final Map<int, String> running = {};
  final List<(int, ProcessSignal)> signals = [];

  /// When true, SIGTERM is ignored and only SIGKILL ends the process.
  bool ignoresTerm = false;

  @override
  Future<String?> commandLineOf(int pid) async => running[pid];

  @override
  bool kill(int pid, ProcessSignal signal) {
    signals.add((pid, signal));
    if (!running.containsKey(pid)) return false;
    if (signal == ProcessSignal.sigkill || !ignoresTerm) running.remove(pid);
    return true;
  }
}

const _exe = '/Applications/MediaHub.app/Contents/MacOS/rqbit';

/// What the real probe reports for our engine on the machine running the
/// tests. `stopOwned` checks the host platform's way: the full command line,
/// or on Windows the image name alone, which is all `tasklist` gives.
final _engineAsProbeSeesIt = Platform.isWindows
    ? p.windows.basename(_exe)
    : _exe;

EngineLaunchRecord _record({
  int pid = 4242,
  String executable = _exe,
  int port = 3030,
  String downloadPath = '/Users/me/Downloads',
  int downloadLimitBytes = 0,
}) => EngineLaunchRecord(
  pid: pid,
  executable: executable,
  port: port,
  downloadPath: downloadPath,
  downloadLimitBytes: downloadLimitBytes,
);

void _reclaimTests() {
  late Directory tmp;
  late EnginePidFile pidFile;
  late _FakeProbe probe;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mediahub_pid');
    pidFile = EnginePidFile(p.join(tmp.path, 'engine', 'rqbit.pid'));
    probe = _FakeProbe();
    RqbitProcessService.resetForTest();
    RqbitProcessService.probe = probe;
    RqbitProcessService.pidFileLocator = () async => pidFile;
  });

  tearDown(() async {
    RqbitProcessService.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<EngineLaunchRecord?> reclaim({
    required EngineLaunchRecord wanted,
    bool portAnswering = true,
  }) => RqbitProcessService.reclaimOrphan(
    pidFile: pidFile,
    probe: probe,
    wanted: wanted,
    portAnswering: () async => portAnswering,
    windows: false,
  );

  group('EngineLaunchRecord', () {
    test('round-trips through JSON', () async {
      await pidFile.write(_record(downloadLimitBytes: 1024));
      final read = await pidFile.read();
      expect(read?.pid, 4242);
      expect(read?.executable, _exe);
      expect(read?.downloadLimitBytes, 1024);
      expect(read!.sameLaunchAs(_record(downloadLimitBytes: 1024)), isTrue);
    });

    test('an unreadable record is ignored, not guessed at', () async {
      await File(pidFile.path).create(recursive: true);
      await File(pidFile.path).writeAsString('{"pid": "not a number"}');
      expect(await pidFile.read(), isNull);
      await File(pidFile.path).writeAsString('garbage');
      expect(await pidFile.read(), isNull);
    });
  });

  group('reclaimOrphan', () {
    test('nothing recorded, nothing to do', () async {
      expect(await reclaim(wanted: _record()), isNull);
      expect(probe.signals, isEmpty);
    });

    test('a recorded process that has exited is forgotten', () async {
      await pidFile.write(_record());
      expect(await reclaim(wanted: _record()), isNull);
      expect(probe.signals, isEmpty);
      expect(await File(pidFile.path).exists(), isFalse);
    });

    test('a recycled PID running something else is never touched', () async {
      await pidFile.write(_record());
      probe.running[4242] = '/usr/bin/some-other-program --serve';
      expect(await reclaim(wanted: _record()), isNull);
      expect(probe.signals, isEmpty, reason: 'not ours — never killed');
      expect(probe.running, contains(4242));
      expect(await File(pidFile.path).exists(), isFalse);
    });

    test('our orphan, launched the same way, is adopted', () async {
      await pidFile.write(_record());
      probe.running[4242] = '$_exe --http-api-listen-addr 127.0.0.1:3030';
      final adopted = await reclaim(wanted: _record(pid: 0));
      expect(adopted?.pid, 4242);
      expect(probe.signals, isEmpty);
    });

    test('our orphan, launched with other settings, is stopped', () async {
      await pidFile.write(_record(downloadPath: '/Volumes/Old'));
      probe.running[4242] = '$_exe --http-api-listen-addr 127.0.0.1:3030';
      expect(await reclaim(wanted: _record(pid: 0)), isNull);
      expect(probe.signals, [(4242, ProcessSignal.sigterm)]);
      expect(probe.running, isNot(contains(4242)));
      expect(await File(pidFile.path).exists(), isFalse);
    });

    test('our orphan that no longer answers is stopped', () async {
      await pidFile.write(_record());
      probe.running[4242] = _exe;
      expect(
        await reclaim(wanted: _record(pid: 0), portAnswering: false),
        isNull,
      );
      expect(probe.signals.first, (4242, ProcessSignal.sigterm));
    });

    test('one that ignores SIGTERM is killed', () async {
      await pidFile.write(_record(port: 4040));
      probe
        ..running[4242] = _exe
        ..ignoresTerm = true;
      expect(await reclaim(wanted: _record(pid: 0)), isNull);
      expect(probe.signals, [
        (4242, ProcessSignal.sigterm),
        (4242, ProcessSignal.sigkill),
      ]);
    });
  });

  group('stopOwned', () {
    test('stops the recorded sidecar and removes the record', () async {
      await pidFile.write(_record());
      probe.running[4242] = _engineAsProbeSeesIt;

      await RqbitProcessService.stopOwned();

      expect(probe.signals.first, (4242, ProcessSignal.sigterm));
      expect(probe.running, isEmpty);
      expect(await File(pidFile.path).exists(), isFalse);
    });

    test('never signals a process that is not our binary', () async {
      await pidFile.write(_record());
      probe.running[4242] = '/bin/zsh';

      await RqbitProcessService.stopOwned();

      expect(probe.signals, isEmpty);
      expect(probe.running, contains(4242));
    });

    test(
      'closing is final: no service may start an engine afterwards',
      () async {
        await RqbitProcessService.stopOwned(closing: true);

        final service = RqbitProcessService(downloadPath: tmp.path);
        addTearDown(service.dispose);
        expect(await service.start(), isFalse);
        expect(service.lastStartFailure, EngineStartFailure.closing);
      },
    );
  });

  group('isEngineCommandLine', () {
    test('matches the full path, with or without arguments', () {
      expect(isEngineCommandLine(_exe, _exe, windows: false), isTrue);
      expect(
        isEngineCommandLine('$_exe server start', _exe, windows: false),
        isTrue,
      );
    });

    test('a different binary with a shared prefix does not match', () {
      expect(
        isEngineCommandLine('${_exe}2 server', _exe, windows: false),
        isFalse,
      );
      expect(
        isEngineCommandLine('/usr/local/bin/rqbit', _exe, windows: false),
        isFalse,
      );
    });

    test('on Windows the image name is all there is to go on', () {
      expect(
        isEngineCommandLine(
          'rqbit.exe',
          r'C:\Program Files\MediaHub\rqbit.exe',
          windows: true,
        ),
        isTrue,
      );
      expect(
        isEngineCommandLine(
          'qbittorrent.exe',
          r'C:\Program Files\MediaHub\rqbit.exe',
          windows: true,
        ),
        isFalse,
      );
    });

    test('reads the image name out of tasklist CSV', () {
      expect(
        SystemEngineProcessProbe.imageNameFromTasklist(
          '"rqbit.exe","1234","Console","1","12,345 K"\r\n',
        ),
        'rqbit.exe',
      );
      expect(
        SystemEngineProcessProbe.imageNameFromTasklist(
          'INFO: No tasks are running which match the specified criteria.',
        ),
        isNull,
      );
    });
  });
}
