import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lets a pushed page be left from the keyboard: Esc, and the platform's
/// "back" chord — ⌘[ on macOS, Alt+← elsewhere.
///
/// Pushed pages (details, settings) had a floating Back button and nothing
/// else, so a keyboard user — or anyone on a page whose Back button was not
/// drawn yet because it was still loading — had no way out.
class BackShortcuts extends StatelessWidget {
  const BackShortcuts({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    void back() => unawaited(Navigator.of(context).maybePop());

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): back,
        // defaultTargetPlatform rather than dart:io's Platform: the same
        // answer in the app, and one a test can vary.
        if (defaultTargetPlatform == TargetPlatform.macOS)
          const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
              back
        else
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): back,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
