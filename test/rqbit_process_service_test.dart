import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/rqbit_process_service.dart';

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
}
