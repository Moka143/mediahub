// Fetches the bundled torrent engine (rqbit) into a release build.
//
// Run after `flutter build <platform> --release` and before packaging:
//
//   dart run tool/fetch_engine.dart
//
// The binary is deliberately **not** committed. It is 13–36 MB depending on
// platform, it changes on every engine upgrade, and a binary in git is a
// binary nobody re-reviews. Instead it is pinned by version *and* SHA-256
// below, downloaded at build time, and verified before it is allowed near a
// bundle. A mismatch is a hard failure, never a warning.
//
// The checksums come from GitHub's own release metadata (`assets[].digest`),
// so bumping [_version] means replacing every hash in [_assets] from the new
// release's metadata:
//
//   curl -sL https://api.github.com/repos/ikatson/rqbit/releases/tags/vX.Y.Z \
//     | jq -r '.assets[] | "\(.name) \(.digest)"'
//
// rqbit is Apache-2.0, so unlike bundling GPLv3 qBittorrent this carries no
// source-offer obligation — only attribution, which lives in the README.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Pinned engine release. Bump this and every hash below together.
const _version = 'v9.0.1';

const _repo = 'ikatson/rqbit';

/// One entry per platform we ship. The desktop/GUI assets in the same release
/// are deliberately not used — we want the headless CLI.
const _assets = <String, ({String name, String sha256})>{
  'windows-x64': (
    name: 'rqbit.exe',
    sha256: '2ed683203beca628e0c45f62f99feeef4242cecc3444c8422dfe5b1b6aa38cea',
  ),
  // One universal binary covers Apple silicon and Intel, so there is no arch
  // split on macOS.
  'macos-universal': (
    name: 'rqbit-osx-universal',
    sha256: 'de8b957b2927dc5bf911506bf3c24c8e77e24a6d21ecd80f6fcffd2db30eb672',
  ),
  'linux-x64': (
    name: 'rqbit-linux-amd64',
    sha256: '82ed2c23f4c7b91bb2c92eaab92e4a850d386cdf337bcdf9e0971c8ce3da4335',
  ),
  'linux-arm64': (
    name: 'rqbit-linux-arm64',
    sha256: '9ac50a7d1917cd458111265a12346a924b4f7cea7520327782ed5bd6f423b561',
  ),
};

/// Returning a non-zero `int` from `main` does **not** set the process exit
/// code in Dart — it is silently ignored. A build step that can fail has to
/// say so through [exitCode], or CI packages whatever it found and calls it a
/// success.
Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  final destOverride = _argValue(args, '--dest');
  final key = _assetKey();

  final asset = _assets[key];
  if (asset == null) {
    stderr.writeln('fetch_engine: no engine asset for $key');
    return 1;
  }

  final destDir = destOverride ?? await _defaultDestination();
  if (destDir == null) {
    stderr.writeln(
      'fetch_engine: could not find a release bundle to copy into.\n'
      'Run `flutter build <platform> --release` first, or pass --dest <dir>.',
    );
    return 1;
  }

  final outName = Platform.isWindows ? 'rqbit.exe' : 'rqbit';
  final out = File(p.join(destDir, outName));

  // The download cache is keyed by version, so a rebuild does not re-fetch and
  // a version bump cannot silently reuse the old binary.
  final cache = File(p.join('build', 'engine-cache', _version, asset.name));

  if (!await cache.exists()) {
    final url =
        'https://github.com/$_repo/releases/download/$_version/${asset.name}';
    stdout.writeln('fetch_engine: downloading $url');
    await cache.parent.create(recursive: true);
    if (!await _download(url, cache)) return 1;
  } else {
    stdout.writeln('fetch_engine: using cached ${cache.path}');
  }

  final digest = sha256.convert(await cache.readAsBytes()).toString();
  if (digest != asset.sha256) {
    // Delete it: leaving a bad binary in the cache means the next run reports
    // "using cached" and fails the same way with a less obvious cause.
    await cache.delete();
    stderr.writeln(
      'fetch_engine: CHECKSUM MISMATCH for ${asset.name}\n'
      '  expected ${asset.sha256}\n'
      '  actual   $digest\n'
      'Refusing to bundle it. The cached copy has been deleted.',
    );
    return 1;
  }

  await out.parent.create(recursive: true);
  await cache.copy(out.path);

  if (!Platform.isWindows) {
    // The GitHub asset arrives without the executable bit.
    final chmod = await Process.run('chmod', ['+x', out.path]);
    if (chmod.exitCode != 0) {
      stderr.writeln('fetch_engine: chmod failed: ${chmod.stderr}');
      return 1;
    }
  }

  if (Platform.isMacOS) {
    if (!await _codesign(out.path)) return 1;
    // Adding a file under Contents/MacOS invalidates the bundle's seal, so
    // the app itself has to be signed again afterwards.
    final bundle = _enclosingAppBundle(out.path);
    if (bundle != null && !await _codesign(bundle, deep: true)) return 1;
  }

  stdout.writeln('fetch_engine: placed ${out.path} (${asset.name} $_version)');
  return 0;
}

String? _argValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

String _assetKey() {
  if (Platform.isWindows) return 'windows-x64';
  if (Platform.isMacOS) return 'macos-universal';
  // `uname -m` rather than a Dart API: there isn't one, and the abi string in
  // Platform.version is not stable enough to parse.
  final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();
  return arch == 'aarch64' || arch == 'arm64' ? 'linux-arm64' : 'linux-x64';
}

/// Where the engine has to land for the app to find it at runtime.
///
/// `RqbitProcessService.bundledPath()` looks beside `Platform.resolvedExecutable`,
/// so this must be the same directory the Flutter runner ends up in. On
/// Windows that one directory feeds all three channels — the portable zip, the
/// MSIX package and the Inno Setup installer all copy the whole Release folder
/// — so there is nothing per-channel to keep in sync.
Future<String?> _defaultDestination() async {
  if (Platform.isWindows) {
    const dir = r'build\windows\x64\runner\Release';
    return await Directory(dir).exists() ? dir : null;
  }

  if (Platform.isMacOS) {
    const products = 'build/macos/Build/Products/Release';
    final dir = Directory(products);
    if (!await dir.exists()) return null;
    await for (final entry in dir.list()) {
      if (entry is Directory && entry.path.endsWith('.app')) {
        return p.join(entry.path, 'Contents', 'MacOS');
      }
    }
    return null;
  }

  const bundle = 'build/linux/x64/release/bundle';
  return await Directory(bundle).exists() ? bundle : null;
}

Future<bool> _download(String url, File dest) async {
  final client = HttpClient();
  try {
    var uri = Uri.parse(url);
    // GitHub redirects release downloads to object storage; HttpClient does
    // not follow cross-host redirects for us.
    for (var hop = 0; hop < 5; hop++) {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();

      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) break;
        uri = uri.resolve(location);
        continue;
      }

      if (response.statusCode != 200) {
        await response.drain<void>();
        stderr.writeln('fetch_engine: HTTP ${response.statusCode} for $uri');
        return false;
      }

      await response.pipe(dest.openWrite());
      return true;
    }
    stderr.writeln('fetch_engine: too many redirects for $url');
    return false;
  } catch (e) {
    stderr.writeln('fetch_engine: download failed: $e');
    return false;
  } finally {
    client.close();
  }
}

/// The `.app` the given path sits inside, or null if it is not in one.
String? _enclosingAppBundle(String path) {
  for (var dir = p.dirname(path); dir.length > 1; dir = p.dirname(dir)) {
    if (dir.endsWith('.app')) return dir;
  }
  return null;
}

/// Ad-hoc sign the sidecar.
///
/// Not optional on macOS, and the failure is confusing without it: the binary
/// sits inside `Contents/MacOS/`, so it is a nested executable of the app
/// bundle, and Xcode refuses to sign a bundle containing an unsigned one. The
/// next `flutter build macos` then dies with a bare
/// "Command CodeSign failed with a nonzero exit code" that says nothing about
/// this file.
///
/// Signing the sidecar alone is not sufficient: dropping any file into
/// `Contents/MacOS` invalidates the bundle's seal, so `codesign --verify`
/// then reports "a sealed resource is missing or invalid" and Gatekeeper
/// rejects the app on another machine. The enclosing `.app` is therefore
/// re-signed afterwards.
///
/// Ad-hoc (`-s -`) matches what Flutter's own macOS release build does for a
/// project with no signing identity. A build meant for distribution must
/// re-sign with the app's Developer ID and the hardened runtime instead, and
/// inside-out rather than with `--deep`, which Apple deprecates for anything
/// being notarized.
Future<bool> _codesign(String path, {bool deep = false}) async {
  final result = await Process.run('codesign', [
    '--force',
    if (deep) '--deep',
    '--sign',
    '-',
    '--timestamp=none',
    path,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('fetch_engine: codesign failed: ${result.stderr}');
    return false;
  }
  return true;
}
