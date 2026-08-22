import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/services/local_media_scanner.dart';

/// `findSubtitles` had no coverage and used `split('/').last.split('\\').last`
/// to derive the video's base name — the exact form `basenameOf` exists to
/// replace. It now uses `basenameOf`; these pin the matching rules that
/// change had to preserve.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mediahub_subs_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<File> touch(String name) async {
    final f = File('${tempDir.path}${Platform.pathSeparator}$name');
    await f.writeAsString('x');
    return f;
  }

  test('finds a sidecar sharing the video base name', () async {
    final video = await touch('Severance.S02E01.1080p.mkv');
    await touch('Severance.S02E01.1080p.srt');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, hasLength(1));
    expect(subs.single, endsWith('.srt'));
  });

  test('finds language-tagged sidecars', () async {
    final video = await touch('Show.S01E01.mkv');
    await touch('Show.S01E01.en.srt');
    await touch('Show.S01E01.fr.srt');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, hasLength(2));
  });

  test('ignores a sidecar belonging to another episode', () async {
    final video = await touch('Show.S01E01.mkv');
    await touch('Show.S01E02.srt');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, isEmpty);
  });

  test('ignores non-subtitle files that share the name', () async {
    final video = await touch('Show.S01E01.mkv');
    await touch('Show.S01E01.nfo');

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, isEmpty);
  });

  test('accepts every subtitle extension it advertises', () async {
    final video = await touch('Show.S01E01.mkv');
    for (final ext in ['srt', 'ass', 'ssa', 'sub', 'vtt']) {
      await touch('Show.S01E01.$ext');
    }

    final subs = await LocalMediaScanner(
      tempDir.path,
    ).findSubtitles(video.path);

    expect(subs, hasLength(5));
  });

  test('a missing directory yields nothing rather than throwing', () async {
    final scanner = LocalMediaScanner('${tempDir.path}/nope');
    expect(await scanner.findSubtitles('${tempDir.path}/nope/x.mkv'), isEmpty);
  });
}
