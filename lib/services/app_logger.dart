import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Severity of a log line. Only [warn] and [error] force an fsync — the rest
/// ride along in the OS buffer, which keeps a chatty poll loop from turning
/// into a syscall storm.
enum LogLevel { debug, info, warn, error }

/// Append-only disk log, written next to `shared_preferences.json`.
///
/// Why this exists: a release build has no console. Without a file on disk,
/// the only record of a failed startup, a stalled stream or a rejected TMDB
/// push is lost the moment the process exits — so a user report can never be
/// turned into a diagnosis.
///
/// **Best-effort by construction.** Every operation swallows its own errors:
/// if logging fails we must not let that failure mask the original problem.
/// The trade-off is that a broken log is silent, so [filePath] is exposed for
/// a "reveal log" affordance rather than assuming the file is always there.
///
/// **Call sites are synchronous.** [d]/[i]/[w]/[e] return void and enqueue the
/// write onto an internal chain, so ordering is preserved without every call
/// site having to await. Use [idle] when you genuinely need the queue drained
/// — notably before `exit()`, where a pending write would otherwise be lost.
///
/// **DEBUG stays off the disk in a release build.** The streaming proxy and
/// the pollers log at DEBUG on every request and every tick; written out, they
/// pushed the startup and shutdown breadcrumbs — the lines a bug report is
/// actually read for — out of the 256 KB window within minutes of playback.
/// INFO, WARN and ERROR are always written. Set `MEDIAHUB_VERBOSE_LOG=1` in
/// the environment to get the DEBUG lines back when diagnosing something.
class AppLog {
  AppLog._();

  /// Environment switch that puts DEBUG lines back into a release log.
  static const String verboseEnvVar = 'MEDIAHUB_VERBOSE_LOG';

  /// Rotate once the active file passes this size. One previous generation is
  /// kept as `mediahub.log.1`.
  ///
  /// The predecessor to this class *deleted* the log at this threshold, which
  /// meant a crash late in a long session destroyed the very breadcrumbs the
  /// log existed to preserve.
  static const int maxBytes = 256 * 1024;

  static const String _fileName = 'mediahub.log';

  /// Lines emitted before [init] completed. Bounded so a failure to
  /// initialise cannot grow this without limit.
  static const int _maxPending = 200;

  static File? _file;
  static bool _initialised = false;
  static Future<void>? _initInFlight;
  static int _bytesWritten = 0;
  static final Queue<String> _pending = Queue<String>();

  /// Serialises appends so concurrent unawaited calls cannot interleave.
  static Future<void> _tail = Future<void>.value();

  /// Whether DEBUG lines reach the file. See the class doc.
  static bool _debugToDisk = _defaultDebugToDisk();

  static bool _defaultDebugToDisk() {
    if (!kReleaseMode) return true;
    try {
      return Platform.environment[verboseEnvVar] == '1';
    } catch (_) {
      // No environment to read is not a reason to fail the logger.
      return false;
    }
  }

  /// Absolute path of the active log file, or null when logging is disabled
  /// because the file could not be opened.
  static String? get filePath => _file?.path;

  /// Completes once every enqueued write has been flushed. Await before
  /// `exit()`.
  static Future<void> get idle => _tail;

  /// Resolve the log file and drain anything buffered before now.
  ///
  /// Idempotent and safe to call concurrently — the startup crash handler
  /// calls it to guarantee a file exists even when `_bootstrap` died before
  /// reaching its own call.
  static Future<void> init() {
    if (_initialised) return Future<void>.value();
    return _initInFlight ??= _init();
  }

  static Future<void> _init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      _bytesWritten = await file.exists() ? await file.length() : 0;
      _file = file;
    } catch (_) {
      // Leave _file null — every write becomes a no-op rather than throwing
      // into whatever was being logged about.
      _file = null;
    }

    _initialised = true;
    _initInFlight = null;

    final buffered = _pending.toList();
    _pending.clear();
    for (final line in buffered) {
      _enqueue(line, flush: false);
    }
    await _tail;
  }

  /// Terse names — the log call sites outnumber everything else in the hot
  /// paths, and `AppLog.d(...)` keeps them to one line.
  static void d(String message) => _log(LogLevel.debug, message);
  static void i(String message) => _log(LogLevel.info, message);
  static void w(String message) => _log(LogLevel.warn, message);
  static void e(String message) => _log(LogLevel.error, message);

  static void _log(LogLevel level, String message) {
    // Keep the debug console behaving exactly as it did before the disk log
    // existed. debugPrint (not print) so the framework still rate-limits.
    if (kDebugMode) debugPrint(message);

    if (level == LogLevel.debug && !_debugToDisk) return;

    final line =
        '[${DateTime.now().toIso8601String()}] '
        '${_label(level)} $message';

    if (!_initialised) {
      _pending.add(line);
      while (_pending.length > _maxPending) {
        _pending.removeFirst();
      }
      return;
    }

    _enqueue(line, flush: level == LogLevel.warn || level == LogLevel.error);
  }

  static void _enqueue(String line, {required bool flush}) {
    _tail = _tail
        .then((_) => _append(line, flush: flush))
        .catchError((Object _) {});
  }

  static Future<void> _append(String line, {required bool flush}) async {
    final file = _file;
    if (file == null) return;

    try {
      if (_bytesWritten >= maxBytes) await _rotate();
      final payload = '$line\n';
      await file.writeAsString(payload, mode: FileMode.append, flush: flush);
      // Byte length, not `payload.length` — that counts UTF-16 code units, so
      // a log full of non-ASCII release names rotated late.
      _bytesWritten += utf8.encode(payload).length;
    } catch (_) {
      // Disk full, permissions, file removed underneath us — all non-fatal.
    }
  }

  static Future<void> _rotate() async {
    final file = _file;
    if (file == null) return;

    try {
      final previous = File('${file.path}.1');
      if (await previous.exists()) await previous.delete();
      await file.rename(previous.path);
    } catch (_) {
      // Rotation failed — truncate instead so the file cannot grow without
      // bound. Losing history beats filling the user's disk.
      try {
        await file.writeAsString('');
      } catch (_) {
        // Deliberately terminal: this *is* the logger. Reporting a logging
        // failure through the logger would recurse, so give up quietly.
      }
    }
    _bytesWritten = 0;
  }

  static String _label(LogLevel level) => switch (level) {
    LogLevel.debug => 'DEBUG',
    LogLevel.info => 'INFO ',
    LogLevel.warn => 'WARN ',
    LogLevel.error => 'ERROR',
  };

  /// Reset internal state. Tests only.
  ///
  /// [debugToDisk] stands in for the release-build default, which a test
  /// (always a debug build) cannot otherwise reach.
  @visibleForTesting
  static Future<void> resetForTest({File? file, bool? debugToDisk}) async {
    await _tail;
    _file = file;
    _initialised = file != null;
    _initInFlight = null;
    _bytesWritten = 0;
    _pending.clear();
    _tail = Future<void>.value();
    _debugToDisk = debugToDisk ?? _defaultDebugToDisk();
  }
}
