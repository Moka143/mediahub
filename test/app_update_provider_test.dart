import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/providers/app_update_provider.dart';
import 'package:mediahub/services/app_shutdown.dart';
import 'package:mediahub/services/app_update_service.dart';

const _release = AppRelease(
  version: '9.9.9',
  installerName: 'mediahub-9.9.9-windows-setup.exe',
  installerUrl: 'https://x.test/setup.exe',
  checksumUrl: 'https://x.test/setup.exe.sha256',
);

class _FakeService extends AppUpdateService {
  _FakeService({this.release, this.failCheck = false, this.failDownload})
    : super(dio: Dio());

  final AppRelease? release;
  final bool failCheck;
  final Object? failDownload;
  final launched = <File>[];

  @override
  Future<AppRelease?> newerRelease() async {
    if (failCheck) throw const SocketException('offline');
    return release;
  }

  @override
  Future<File> download(
    AppRelease release, {
    void Function(double fraction)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (failDownload case final error?) throw error;
    onProgress?.call(0.5);
    return File('setup.exe');
  }

  @override
  Future<void> launch(File installer) async => launched.add(installer);
}

class _FakeShutdown extends AppShutdown {
  int runs = 0;

  @override
  Future<void> run() async => runs++;
}

void main() {
  late _FakeShutdown shutdown;
  setUp(() => shutdown = _FakeShutdown());

  ProviderContainer container(_FakeService service) {
    final c = ProviderContainer(
      overrides: [
        appUpdateServiceProvider.overrideWithValue(service),
        appUpdateAutoCheckProvider.overrideWithValue(false),
        appShutdownProvider.overrideWithValue(shutdown),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a newer release is offered on the banner', () async {
    final c = container(_FakeService(release: _release));
    await c.read(appUpdateProvider.notifier).check();
    final state = c.read(appUpdateProvider);
    expect(state.stage, AppUpdateStage.available);
    expect(state.release, _release);
    expect(state.showsBanner, isTrue);
  });

  test('no newer release: up to date, and no banner', () async {
    final c = container(_FakeService());
    await c.read(appUpdateProvider.notifier).check();
    expect(c.read(appUpdateProvider).stage, AppUpdateStage.upToDate);
    expect(c.read(appUpdateProvider).showsBanner, isFalse);
  });

  test(
    'an automatic check that fails says nothing; an asked one does',
    () async {
      final c = container(_FakeService(failCheck: true));
      final notifier = c.read(appUpdateProvider.notifier);

      await notifier.check();
      expect(c.read(appUpdateProvider).stage, AppUpdateStage.idle);

      await notifier.check(userAsked: true);
      expect(c.read(appUpdateProvider).stage, AppUpdateStage.failed);
      expect(c.read(appUpdateProvider).error, contains("Couldn't check"));
    },
  );

  test('installing starts the installer, then quits the app', () async {
    final service = _FakeService(release: _release);
    final c = container(service);
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.check();

    await notifier.install();

    expect(service.launched, hasLength(1));
    expect(shutdown.runs, 1);
    expect(c.read(appUpdateProvider).stage, AppUpdateStage.installing);
  });

  test('a failed download keeps the app open and offers a retry', () async {
    final service = _FakeService(
      release: _release,
      failDownload: const AppUpdateException('The download was damaged.'),
    );
    final c = container(service);
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.check();

    await notifier.install();

    final state = c.read(appUpdateProvider);
    expect(state.stage, AppUpdateStage.failed);
    expect(state.error, 'The download was damaged.');
    expect(state.showsBanner, isTrue, reason: 'it offers "Try again"');
    expect(service.launched, isEmpty);
    expect(shutdown.runs, 0);
  });

  test('closing the banner only hides it', () async {
    final c = container(_FakeService(release: _release));
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.check();
    notifier.dismiss();
    expect(c.read(appUpdateProvider).showsBanner, isFalse);
    expect(c.read(appUpdateProvider).release, _release);
  });
}
