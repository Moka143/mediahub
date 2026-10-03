import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_logger.dart';

/// The sidecar this app launched, as written to disk so a later launch can
/// recognise it.
///
/// Everything a later launch needs to decide whether the process it finds is
/// *ours* (the executable it was started from) and whether it is *usable*
/// as-is (the settings it was started with).
@immutable
class EngineLaunchRecord {
  const EngineLaunchRecord({
    required this.pid,
    required this.executable,
    required this.port,
    required this.downloadPath,
    this.downloadLimitBytes = 0,
    this.uploadLimitBytes = 0,
  });

  final int pid;

  /// Absolute path of the binary that was launched.
  final String executable;

  final int port;
  final String downloadPath;
  final int downloadLimitBytes;
  final int uploadLimitBytes;

  Map<String, Object> toJson() => {
    'pid': pid,
    'executable': executable,
    'port': port,
    'downloadPath': downloadPath,
    'downloadLimitBytes': downloadLimitBytes,
    'uploadLimitBytes': uploadLimitBytes,
  };

  /// Null for anything that is not a complete record — a half-written file
  /// is a reason to leave the process alone, not to guess.
  static EngineLaunchRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final pid = json['pid'];
    final executable = json['executable'];
    final port = json['port'];
    final downloadPath = json['downloadPath'];
    if (pid is! int ||
        pid <= 0 ||
        executable is! String ||
        executable.isEmpty ||
        port is! int ||
        downloadPath is! String) {
      return null;
    }
    return EngineLaunchRecord(
      pid: pid,
      executable: executable,
      port: port,
      downloadPath: downloadPath,
      downloadLimitBytes: json['downloadLimitBytes'] as int? ?? 0,
      uploadLimitBytes: json['uploadLimitBytes'] as int? ?? 0,
    );
  }

  /// Whether a process launched like this one can be used as it is.
  bool sameLaunchAs(EngineLaunchRecord other) =>
      executable == other.executable &&
      port == other.port &&
      p.equals(downloadPath, other.downloadPath) &&
      downloadLimitBytes == other.downloadLimitBytes &&
      uploadLimitBytes == other.uploadLimitBytes;

  /// Same process, launched to listen where [other] wants it.
  bool sameEndpointAs(EngineLaunchRecord other) =>
      port == other.port && p.equals(downloadPath, other.downloadPath);

  @override
  String toString() => 'pid $pid on port $port ($executable)';
}

/// Where the record lives: `<app support>/engine/rqbit.pid`.
///
/// Beside rqbit's own session state, which it reads by name (`session.json`
/// and one `.torrent` per info hash) and does not enumerate.
class EnginePidFile {
  EnginePidFile(this.path);

  final String path;

  Future<EngineLaunchRecord?> read() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return EngineLaunchRecord.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      AppLog.w('[EnginePidFile] unreadable $path ($e) — ignoring it');
      return null;
    }
  }

  Future<void> write(EngineLaunchRecord record) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(record.toJson()), flush: true);
    } catch (e) {
      // Without the record a crash leaves an orphan the next launch cannot
      // recognise — worth a line, not worth failing the start over.
      AppLog.w('[EnginePidFile] could not write $path: $e');
    }
  }

  Future<void> delete() async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLog.w('[EnginePidFile] could not delete $path: $e');
    }
  }
}

/// Asks the operating system about one process. An interface so the reclaim
/// logic can be tested without real processes.
abstract class EngineProcessProbe {
  /// The command line of process [pid] as the OS reports it — the full one
  /// from `ps` on macOS and Linux, the image name from `tasklist` on Windows —
  /// or null when no such process is running.
  Future<String?> commandLineOf(int pid);

  /// Send [signal] to [pid]. False when there was nothing to signal.
  bool kill(int pid, ProcessSignal signal);
}

/// The real thing: `ps` / `tasklist`, and [Process.killPid].
class SystemEngineProcessProbe implements EngineProcessProbe {
  const SystemEngineProcessProbe();

  @override
  Future<String?> commandLineOf(int pid) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('tasklist', [
          '/FI',
          'PID eq $pid',
          '/FO',
          'CSV',
          '/NH',
        ]);
        if (result.exitCode != 0) return null;
        return imageNameFromTasklist(result.stdout as String);
      }
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'command=']);
      if (result.exitCode != 0) return null;
      final line = (result.stdout as String).trim();
      return line.isEmpty ? null : line;
    } catch (e) {
      AppLog.w('[EnginePidFile] could not look up pid $pid: $e');
      return null;
    }
  }

  @override
  bool kill(int pid, ProcessSignal signal) {
    try {
      return Process.killPid(pid, signal);
    } catch (_) {
      return false;
    }
  }

  /// The image name from one line of `tasklist /FO CSV /NH`, e.g.
  /// `"rqbit.exe","1234","Console","1","12,345 K"`. Null for its "no tasks"
  /// message, which is not CSV.
  @visibleForTesting
  static String? imageNameFromTasklist(String output) {
    final line = output.trim().split('\n').first.trim();
    if (!line.startsWith('"')) return null;
    final end = line.indexOf('"', 1);
    if (end <= 1) return null;
    return line.substring(1, end);
  }
}

/// Whether [commandLine] — as [EngineProcessProbe.commandLineOf] reported it
/// — is the engine binary at [executable].
///
/// On macOS and Linux that is the full path, which a recycled process ID
/// running anything else cannot match. Windows' `tasklist` only gives the
/// image name, so there the test is the file name.
bool isEngineCommandLine(
  String commandLine,
  String executable, {
  required bool windows,
}) {
  if (windows) {
    return commandLine.trim().toLowerCase() ==
        p.windows.basename(executable).toLowerCase();
  }
  final line = commandLine.trim();
  return line == executable || line.startsWith('$executable ');
}
