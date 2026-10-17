import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/app_update_service.dart';

/// Answers every request from [files], keyed by URL.
class _FilesAdapter implements HttpClientAdapter {
  _FilesAdapter(this.files);

  final Map<String, List<int>> files;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = files[options.uri.toString()];
    if (body == null) return ResponseBody.fromString('', 404);
    return ResponseBody.fromBytes(
      body,
      200,
      headers: {
        Headers.contentLengthHeader: ['${body.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _release({bool withChecksum = true}) => {
  'tag_name': 'v0.9.0',
  'assets': [
    {
      'name': 'mediahub.msix',
      'browser_download_url': 'https://x.test/mediahub.msix',
    },
    {
      'name': 'mediahub-0.9.0-windows-setup.exe',
      'browser_download_url': 'https://x.test/setup.exe',
    },
    if (withChecksum)
      {
        'name': 'mediahub-0.9.0-windows-setup.exe.sha256',
        'browser_download_url': 'https://x.test/setup.exe.sha256',
      },
  ],
};

void main() {
  group('isNewerVersion', () {
    test('compares each part as a number', () {
      expect(isNewerVersion('0.10.0', '0.9.0'), isTrue);
      expect(isNewerVersion('1.0.0', '0.99.99'), isTrue);
      expect(isNewerVersion('0.9.1', '0.9.0'), isTrue);
    });

    test('the same or an older version is not newer', () {
      expect(isNewerVersion('0.9.0', '0.9.0'), isFalse);
      expect(isNewerVersion('0.8.9', '0.9.0'), isFalse);
    });

    test('ignores a leading v and any build or pre-release tail', () {
      expect(isNewerVersion('v0.9.0', '0.8.0'), isTrue);
      expect(isNewerVersion('0.9.0+3', '0.9.0'), isFalse);
      expect(isNewerVersion('0.9.1-beta', '0.9.0'), isTrue);
    });

    test('a version that does not parse is never newer', () {
      // A malformed tag must not start an install.
      expect(isNewerVersion('latest', '0.9.0'), isFalse);
      expect(isNewerVersion('1.0', '0.9.0'), isFalse);
    });
  });

  group('parseLatestRelease', () {
    test('picks the setup exe and its checksum, never the MSIX', () {
      final release = parseLatestRelease(_release())!;
      expect(release.version, '0.9.0');
      expect(release.installerName, 'mediahub-0.9.0-windows-setup.exe');
      expect(release.installerUrl, 'https://x.test/setup.exe');
      expect(release.checksumUrl, 'https://x.test/setup.exe.sha256');
    });

    test('a release from before the updater has no checksum', () {
      expect(
        parseLatestRelease(_release(withChecksum: false))!.checksumUrl,
        isNull,
      );
    });

    test('a release with no installer is not one', () {
      expect(
        parseLatestRelease({'tag_name': 'v0.9.0', 'assets': <Object>[]}),
        isNull,
      );
      expect(parseLatestRelease(const {'message': 'Not Found'}), isNull);
    });
  });

  group('parseChecksum', () {
    final hash = 'A' * 64;

    test('reads the sha256sum format, in lower case', () {
      expect(parseChecksum('$hash  setup.exe\n'), 'a' * 64);
      expect(parseChecksum(hash), 'a' * 64);
    });

    test('anything that is not a SHA-256 is no checksum', () {
      expect(parseChecksum(''), isNull);
      expect(parseChecksum('abc  setup.exe'), isNull);
    });
  });

  group('download', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mh-update-'));
    tearDown(() => dir.deleteSync(recursive: true));

    AppUpdateService service(Map<String, List<int>> files) => AppUpdateService(
      dio: Dio()..httpClientAdapter = _FilesAdapter(files),
      downloadDir: () async => dir,
    );

    final installer = utf8.encode('pretend installer');
    final good = sha256.convert(installer).toString();

    test('returns an installer that matches its checksum', () async {
      final file = await service({
        'https://x.test/setup.exe': installer,
        'https://x.test/setup.exe.sha256': utf8.encode('$good  setup.exe'),
      }).download(parseLatestRelease(_release())!);
      expect(await file.readAsBytes(), installer);
    });

    test('deletes, and never returns, one that does not', () async {
      final bad = sha256.convert(utf8.encode('something else')).toString();
      await expectLater(
        service({
          'https://x.test/setup.exe': installer,
          'https://x.test/setup.exe.sha256': utf8.encode(bad),
        }).download(parseLatestRelease(_release())!),
        throwsA(isA<AppUpdateException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  });

  test('the installer runs silently, closes the app and reopens it', () async {
    final started = <(String, List<String>)>[];
    await AppUpdateService(
      dio: Dio(),
      start: (exe, args) async => started.add((exe, args)),
    ).launch(File('C:/tmp/setup.exe'));
    expect(started.single.$1, 'C:/tmp/setup.exe');
    expect(
      started.single.$2,
      containsAll(['/SILENT', '/CLOSEAPPLICATIONS', '/UPDATE=1']),
    );
  });
}
