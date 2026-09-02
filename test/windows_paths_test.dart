import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/utils/constants.dart';
import 'package:mediahub/utils/platform_utils.dart';

/// Tests for the Windows-shaped path handling.
///
/// These run on every platform because they are string and environment
/// logic, not filesystem calls — which matters, since CI runs the suite on
/// Ubuntu and the behaviour they protect only ever bites on Windows.
void main() {
  group('expandWindowsVars', () {
    const env = {
      'ProgramFiles': r'C:\Program Files',
      'LOCALAPPDATA': r'C:\Users\murad\AppData\Local',
      'OneDrive': r'C:\Users\murad\OneDrive',
    };

    test('expands a variable', () {
      expect(
        PlatformUtils.expandWindowsVars(
          r'%ProgramFiles%\qBittorrent\qbittorrent.exe',
          environment: env,
        ),
        r'C:\Program Files\qBittorrent\qbittorrent.exe',
      );
    });

    test('expands several in one string', () {
      expect(
        PlatformUtils.expandWindowsVars(
          r'%ProgramFiles%;%LOCALAPPDATA%',
          environment: env,
        ),
        r'C:\Program Files;C:\Users\murad\AppData\Local',
      );
    });

    test('returns null when a variable is missing', () {
      // The caller must skip the candidate rather than probe a path with a
      // literal `%ProgramFiles(x86)%` in it — which is what a 64-bit-only
      // machine would otherwise get.
      expect(
        PlatformUtils.expandWindowsVars(
          r'%ProgramFiles(x86)%\qBittorrent\qbittorrent.exe',
          environment: env,
        ),
        isNull,
      );
    });

    test('leaves a string with no variables alone', () {
      expect(
        PlatformUtils.expandWindowsVars(
          r'C:\Program Files\qBittorrent\qbittorrent.exe',
          environment: env,
        ),
        r'C:\Program Files\qBittorrent\qbittorrent.exe',
      );
    });

    test('a lone percent sign is not treated as a variable', () {
      expect(
        PlatformUtils.expandWindowsVars('100% done', environment: env),
        '100% done',
      );
    });
  });

  group('qBittorrentCandidates', () {
    test('is empty off Windows, where `which` already works', () {
      // Guarded so the list never shadows a real PATH lookup on macOS/Linux.
      if (Platform.isWindows) return;
      expect(PlatformUtils.qBittorrentCandidates(), isEmpty);
    });

    test('covers 64-bit, 32-bit and per-user installs', () {
      final candidates = PlatformUtils.qBittorrentCandidates(
        environment: const {
          'ProgramFiles': r'C:\Program Files',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
          'LOCALAPPDATA': r'C:\Users\murad\AppData\Local',
          'USERPROFILE': r'C:\Users\murad',
        },
      );
      expect(
        candidates,
        contains(r'C:\Program Files (x86)\qBittorrent\qbittorrent.exe'),
      );
      expect(
        candidates,
        contains(
          r'C:\Users\murad\AppData\Local\Programs\qBittorrent'
          r'\qbittorrent.exe',
        ),
      );
    }, skip: !Platform.isWindows ? 'Windows-only path list' : false);

    test('drops duplicates case-insensitively', () {
      // %ProgramFiles% normally expands to the same literal the hardcoded
      // fallback already carries; probing it twice is wasted I/O.
      final candidates = PlatformUtils.qBittorrentCandidates(
        environment: const {
          'ProgramFiles': r'C:\Program Files',
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
          'LOCALAPPDATA': r'C:\Users\murad\AppData\Local',
          'USERPROFILE': r'C:\Users\murad',
        },
      );
      final lowered = candidates.map((c) => c.toLowerCase()).toList();
      expect(lowered.toSet().length, lowered.length);
    }, skip: !Platform.isWindows ? 'Windows-only path list' : false);

    test('every fallback is absolute or a variable reference', () {
      // A relative candidate would resolve against the working directory,
      // which for a launched .exe is wherever Explorer felt like.
      for (final candidate in QBittorrentPaths.windowsFallbacks) {
        expect(
          candidate.startsWith('%') ||
              RegExp(r'^[A-Za-z]:\\').hasMatch(candidate),
          isTrue,
          reason: candidate,
        );
      }
    });

    test('every fallback names the executable', () {
      for (final candidate in QBittorrentPaths.windowsFallbacks) {
        expect(
          candidate.toLowerCase(),
          endsWith('qbittorrent.exe'),
          reason: candidate,
        );
      }
    });
  });

  group('basenameOf', () {
    test('handles a Windows path produced on another host', () {
      // qBittorrent running on Windows reports `Show\S01E01.mkv`, and
      // `path.basename` on a macOS host treats the backslash as an ordinary
      // character — so the whole string survives as the "file name".
      expect(basenameOf(r'Show\S01E01.mkv'), 'S01E01.mkv');
      expect(
        basenameOf(r'C:\Users\murad\Downloads\Show.S01E01.mkv'),
        'Show.S01E01.mkv',
      );
    });

    test('handles a POSIX path', () {
      expect(basenameOf('/library/Show.S01E01.mkv'), 'Show.S01E01.mkv');
    });

    test('handles mixed separators', () {
      // Windows accepts forward slashes, so both turn up in one string.
      expect(basenameOf(r'C:\Downloads/Show\S01E01.mkv'), 'S01E01.mkv');
    });

    test('a bare name is its own basename', () {
      expect(basenameOf('Show.S01E01.mkv'), 'Show.S01E01.mkv');
    });

    test('a trailing separator yields empty rather than throwing', () {
      expect(basenameOf(r'C:\Downloads\'), '');
    });
  });
}
