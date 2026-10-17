import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_logger.dart';
import '../services/app_shutdown.dart';
import '../services/app_update_service.dart';

final appUpdateServiceProvider = Provider<AppUpdateService>(
  (ref) => AppUpdateService(),
);

/// Whether this build checks for updates on its own: a release build on
/// Windows, the one platform with an installer to update from. Overridden in
/// tests.
final appUpdateAutoCheckProvider = Provider<bool>(
  (ref) => kReleaseMode && Platform.isWindows,
);

enum AppUpdateStage {
  /// Not checked yet, or an automatic check that failed quietly.
  idle,
  checking,
  upToDate,
  available,
  downloading,

  /// The installer is running; the app is about to quit.
  installing,
  failed,
}

@immutable
class AppUpdateState {
  const AppUpdateState({
    this.stage = AppUpdateStage.idle,
    this.release,
    this.progress = 0,
    this.error,
    this.dismissed = false,
  });

  final AppUpdateStage stage;

  /// The newer release, once one has been found.
  final AppRelease? release;

  /// Download progress, 0–1.
  final double progress;

  /// What went wrong, for [AppUpdateStage.failed].
  final String? error;

  /// The banner was closed. The update stays available in Settings → About.
  final bool dismissed;

  bool get isBusy =>
      stage == AppUpdateStage.checking ||
      stage == AppUpdateStage.downloading ||
      stage == AppUpdateStage.installing;

  /// Whether Home's banner has something to say.
  bool get showsBanner =>
      !dismissed &&
      release != null &&
      (stage == AppUpdateStage.available ||
          stage == AppUpdateStage.downloading ||
          stage == AppUpdateStage.installing ||
          stage == AppUpdateStage.failed);

  AppUpdateState copyWith({
    AppUpdateStage? stage,
    AppRelease? release,
    double? progress,
    String? error,
    bool? dismissed,
  }) => AppUpdateState(
    stage: stage ?? this.stage,
    release: release ?? this.release,
    progress: progress ?? this.progress,
    error: error,
    dismissed: dismissed ?? this.dismissed,
  );
}

/// When to look for an update, and the steps of installing one: download,
/// verify, start the installer, quit.
class AppUpdateNotifier extends Notifier<AppUpdateState> {
  /// Long enough for startup — engine, library scan, first TMDB calls — to
  /// be out of the way; an update can wait a few seconds.
  static const Duration autoCheckDelay = Duration(seconds: 8);

  CancelToken? _download;

  @override
  AppUpdateState build() {
    Timer? timer;
    if (ref.read(appUpdateAutoCheckProvider)) {
      timer = Timer(autoCheckDelay, () => unawaited(check()));
    }
    ref.onDispose(() {
      timer?.cancel();
      _download?.cancel();
    });
    return const AppUpdateState();
  }

  /// Look for a newer release. An automatic check fails quietly — being
  /// offline is no news — while one the user asked for says so.
  Future<void> check({bool userAsked = false}) async {
    if (state.isBusy) return;
    state = state.copyWith(stage: AppUpdateStage.checking);
    try {
      final release = await ref.read(appUpdateServiceProvider).newerRelease();
      if (!ref.mounted) return;
      if (release == null) {
        state = state.copyWith(stage: AppUpdateStage.upToDate);
        return;
      }
      AppLog.i('[Update] ${release.version} is available');
      state = state.copyWith(
        stage: AppUpdateStage.available,
        release: release,
        dismissed: false,
      );
    } catch (e) {
      AppLog.w('[Update] check failed: $e');
      if (!ref.mounted) return;
      state = userAsked
          ? state.copyWith(
              stage: AppUpdateStage.failed,
              error: "Couldn't check for updates. Check your connection.",
            )
          : state.copyWith(stage: AppUpdateStage.idle);
    }
  }

  /// Download the update, start its installer and quit, so the installer
  /// can replace the app's files. The installer starts the new version.
  Future<void> install() async {
    final release = state.release;
    if (release == null || state.isBusy) return;
    final service = ref.read(appUpdateServiceProvider);
    final cancel = _download = CancelToken();
    state = state.copyWith(stage: AppUpdateStage.downloading, progress: 0);
    try {
      final installer = await service.download(
        release,
        cancelToken: cancel,
        onProgress: (fraction) {
          // Whole percents: the callback fires per chunk, and each state
          // change rebuilds the banner.
          if (!ref.mounted) return;
          final rounded = (fraction * 100).floorToDouble() / 100;
          if (rounded != state.progress) {
            state = state.copyWith(progress: rounded);
          }
        },
      );
      if (!ref.mounted) return;
      state = state.copyWith(stage: AppUpdateStage.installing, progress: 1);
      AppLog.i('[Update] starting ${installer.path}');
      await service.launch(installer);
      await ref.read(appShutdownProvider).run();
    } catch (e) {
      AppLog.w('[Update] install failed: $e');
      if (!ref.mounted) return;
      state = state.copyWith(
        stage: AppUpdateStage.failed,
        error: e is AppUpdateException
            ? e.message
            : "Couldn't download the update. Check your connection and try "
                  'again.',
      );
    } finally {
      _download = null;
    }
  }

  /// Hide the banner for this run.
  void dismiss() => state = state.copyWith(dismissed: true);
}

final appUpdateProvider = NotifierProvider<AppUpdateNotifier, AppUpdateState>(
  AppUpdateNotifier.new,
);
