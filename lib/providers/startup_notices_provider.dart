import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True when this launch found the app's preferences file unreadable and
/// started again from defaults (see `loadPrefsSafe`).
///
/// Overridden in `main` with what prefs recovery reported; false everywhere
/// else, including tests. The UI shows a one-time notice when it is true —
/// otherwise the user just finds their settings, favourites and history gone
/// with no word as to why.
final prefsWereResetProvider = Provider<bool>((ref) => false);
