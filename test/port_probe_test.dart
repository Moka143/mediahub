import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/utils/platform_utils.dart';

void main() {
  group('PlatformUtils.isPortInUse', () {
    test('answers true for a port something is listening on', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((s) => s.destroy());

      expect(
        await PlatformUtils.isPortInUse(server.port, host: '127.0.0.1'),
        isTrue,
      );
    });

    test('answers false for a port nothing is listening on', () async {
      // Bind then release, so the port is a real one and certainly free.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      expect(await PlatformUtils.isPortInUse(port, host: '127.0.0.1'), isFalse);
    });

    test('releases the descriptor when the peer holds the connection', () async {
      // The regression this exists for, and the reason it is written the hard
      // way. The probe used to end in `await socket.close()`, which is a
      // *half*-close: it shuts down our sending direction and hands the
      // descriptor back only once the read side finishes too. dart:io will not
      // deliver the read-close event to a socket nobody called `listen()` on —
      // `issueReadEvent` returns early unless `sendReadEvents` is set, and only
      // a subscription sets it — so the descriptor was never released.
      //
      // It only shows up against a peer that KEEPS THE CONNECTION OPEN. A test
      // server that closes its side immediately sends us a FIN, which tears
      // our socket down anyway and hides the bug entirely. rqbit's HTTP server
      // is the realistic case: it accepts, waits for a request that never
      // comes, and holds the socket. So this server holds too.
      //
      // The engine health check runs this probe every five seconds, against
      // exactly that server — 720 descriptors an hour for as long as the app
      // is open, whether or not anything is downloading. It was the only cost
      // in the app that grew purely with uptime.
      if (!File('/usr/sbin/lsof').existsSync()) {
        markTestSkipped('needs lsof to count this process\'s own sockets');
        return;
      }

      int openTcpSockets() {
        final out =
            Process.runSync('/usr/sbin/lsof', ['-a', '-p', '$pid', '-i']).stdout
                as String;
        return out.split('\n').where((l) => l.contains('TCP')).length;
      }

      // Accepted sockets are parked here on purpose and never closed, so the
      // probe's peer behaves like a real HTTP server waiting for a request.
      final held = <Socket>[];
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await server.close();
      });
      server.listen(held.add);

      const probes = 30;
      final before = openTcpSockets();
      for (var i = 0; i < probes; i++) {
        expect(
          await PlatformUtils.isPortInUse(server.port, host: '127.0.0.1'),
          isTrue,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final grew = openTcpSockets() - before;

      // Both ends of every probe live in this process, so the server's parked
      // halves account for `probes` sockets on their own and cannot be
      // avoided. What must NOT be there is the other `probes` — our own client
      // descriptors. The old code scored ~2x probes here; the fix scores ~1x.
      expect(
        grew,
        lessThan(probes + probes ~/ 2),
        reason:
            'sockets grew by $grew after $probes probes; anything approaching '
            '${probes * 2} means the client descriptors are leaking again',
      );
    });
  });
}
