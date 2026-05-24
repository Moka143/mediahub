import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/streaming_provider.dart';
import '../widgets/streaming_progress_overlay.dart';

/// Shared streaming-overlay + subscription lifecycle for the movie /
/// show details screens.
///
/// Both screens own a floating `OverlayEntry` (the streaming progress
/// overlay), a `ValueNotifier<StreamingOverlayData>` (the overlay's
/// live state), and a `ProviderSubscription` to the streaming sessions
/// notifier. Lifecycle disposal is identical between the two; mixing
/// this mixin in centralizes the field declarations and `dispose()`
/// helper so the two screens can't drift on cleanup.
///
/// The mixin intentionally does NOT capture the orchestration
/// (`_startStreamingSession` / `_handleSessionState`) — those bodies
/// differ enough between movies and shows (parameter shape, navigation
/// arguments, season-pack handling) that abstracting them adds more
/// surface area than it saves. Future work: extract the
/// `_handleSessionState` switch into a generic dispatcher.
mixin DetailsPlaybackController<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// Floating overlay showing buffering / ready progress.
  OverlayEntry? streamingOverlay;

  /// Live state behind [streamingOverlay] — mutate to update the
  /// overlay in-place without rebuilding it.
  ValueNotifier<StreamingOverlayData>? streamingOverlayData;

  /// Subscription to `streamingSessionsProvider` — uses
  /// `listenManual` rather than `ref.listen` so it survives even when
  /// the screen rebuilds (we re-create it explicitly when starting a
  /// new session).
  ProviderSubscription<StreamingSessionsState>? monitorSubscription;

  /// Tear down all three lifecycle pieces. Call from each screen's
  /// `dispose()` before `super.dispose()`.
  void disposePlaybackController() {
    monitorSubscription?.close();
    streamingOverlay?.remove();
    streamingOverlayData?.dispose();
  }

  /// Drop the current overlay + data + subscription without disposing
  /// the State. Useful when transitioning from one streaming session
  /// to another, or when reaching a terminal state (ready / error /
  /// cancelled).
  void dismissPlaybackOverlay() {
    monitorSubscription?.close();
    monitorSubscription = null;
    streamingOverlay?.remove();
    streamingOverlay = null;
    streamingOverlayData?.dispose();
    streamingOverlayData = null;
  }
}
