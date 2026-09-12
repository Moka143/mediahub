import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mediahub/utils/constants.dart';

void main() {
  test('the About screen reports the version that actually shipped', () {
    // AppConstants.appVersion is hand-copied from pubspec.yaml, and it
    // drifted: About said 0.4.1 while the app had been 0.5.0 for two
    // releases. A hand-copied constant only stays honest if something fails
    // when it stops matching.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(
      r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);

    expect(declared, isNotNull, reason: 'no version: line in pubspec.yaml');
    expect(
      AppConstants.appVersion,
      declared,
      reason:
          'AppConstants.appVersion ($AppConstants.appVersion) does not match '
          'pubspec.yaml ($declared) — update lib/utils/constants.dart',
    );
  });

  test('the MSIX package version tracks it too', () {
    // Windows refuses to upgrade a package whose version did not increase,
    // so an msix_version left behind makes the installer silently a no-op.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final msix = RegExp(
      r'^\s*msix_version:\s*([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+',
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);

    expect(msix, AppConstants.appVersion);
  });
}
