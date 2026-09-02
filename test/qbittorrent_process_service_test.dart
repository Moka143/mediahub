import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/qbittorrent_process_service.dart';
import 'package:mediahub/utils/platform_utils.dart';

/// Tests for the one decision this service makes without touching the
/// network or the filesystem: whether it is allowed to spawn a process at
/// all.
///
/// Everything else here — `isRunning`, `findExecutable`, `start` — either
/// opens a socket or launches a binary, and is out of scope for a unit test.
/// This part is not, and it is the part with a history: pointing the app at
/// a qBittorrent on another machine used to have the health check try to
/// spawn a *local* qBittorrent every five seconds, because probing our own
/// loopback port answered "not running" forever while the remote one was
/// perfectly healthy.
void main() {
  QBittorrentProcessService serviceFor(String host) =>
      QBittorrentProcessService(host: host, qbittorrentPath: '/nonexistent');

  group('managesLocalProcess', () {
    test('is true for every spelling of this machine', () {
      for (final host in [
        'localhost',
        '127.0.0.1',
        '::1',
        '0.0.0.0',
        '',
        '  localhost  ',
        'LOCALHOST',
      ]) {
        expect(
          serviceFor(host).managesLocalProcess,
          isTrue,
          reason: 'host "$host"',
        );
      }
    });

    test('is false for a host we cannot start a process on', () {
      for (final host in [
        '192.168.1.50',
        'nas.local',
        'seedbox.example.com',
        '10.0.0.2',
        '127.0.0.2',
      ]) {
        expect(
          serviceFor(host).managesLocalProcess,
          isFalse,
          reason: 'host "$host"',
        );
      }
    });

    test('agrees with PlatformUtils.isLocalHost', () {
      // The service reads this through one helper; if they ever diverge, the
      // health check and the connection banner disagree about the same host.
      for (final host in ['localhost', '127.0.0.1', 'nas.local', '10.0.0.2']) {
        expect(
          serviceFor(host).managesLocalProcess,
          PlatformUtils.isLocalHost(host),
          reason: 'host "$host"',
        );
      }
    });
  });

  group('lifecycle', () {
    test('dispose is safe on a service that never started', () {
      // Reached on every settings change: the provider rebuilds this service
      // and disposes the old one, which may never have run.
      final service = serviceFor('localhost');
      expect(service.dispose, returnsNormally);
    });

    test('dispose is idempotent', () {
      final service = serviceFor('localhost');
      service.dispose();
      expect(service.dispose, returnsNormally);
    });

    test('a remote service refuses to start a local process', () async {
      // The guard that matters. `start()` on a remote host must not reach
      // Process.start; it reports whether the remote is reachable instead.
      // Port 1 on a host that does not resolve fails fast.
      final service = QBittorrentProcessService(
        host: 'invalid.host.that.does.not.resolve',
        port: 1,
        qbittorrentPath: '/nonexistent',
      );
      addTearDown(service.dispose);
      expect(await service.start(), isFalse);
    });
  });
}
