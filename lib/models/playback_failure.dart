import 'package:flutter/foundation.dart';

/// Why a file could not be played, in terms the player can explain.
enum PlaybackFailureKind {
  /// The file can't be opened: moved, deleted, or on a drive that is gone.
  missingFile,

  /// mpv could not read it as video — a damaged file, or, far more often,
  /// one whose data has not been downloaded yet.
  unreadable,

  /// The stream stopped answering: the engine, or the local proxy in front
  /// of it, went away.
  streamUnavailable,
}

/// A file that failed to play.
@immutable
class PlaybackFailure {
  const PlaybackFailure({
    required this.kind,
    required this.generation,
    required this.detail,
  });

  final PlaybackFailureKind kind;

  /// [PlayerService.generation] of the open that failed, so a screen can
  /// ignore a failure that belongs to a file it did not open.
  final int generation;

  /// mpv's own words. For the log — never shown to the user.
  final String detail;
}
