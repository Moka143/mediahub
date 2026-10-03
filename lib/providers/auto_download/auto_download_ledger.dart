import '../../models/auto_download_event.dart';
import '../../models/auto_download_state.dart';
import '../../services/auto_download_service.dart';
import '../../utils/formatters.dart';

/// Key for [AutoDownloadState.downloadQueue]: `<showId>_S01E01`.
///
/// The one producer, so every writer and reader agrees byte for byte;
/// `AutoDownloadNotifier.queueKeyFor` is this, under the name tests use.
String downloadQueueKey(int showId, int season, int episode) =>
    '${showId}_${Formatters.episodeCode(season, episode)}';

/// Whether recording [season]x[episode] moves a show's [tracking] forward:
/// it is at or past the tracked episode, or the show has none yet.
///
/// A manual grab of an old episode must not drag the tracking back — the
/// background check would then fetch onward from there.
bool movesTracking(EpisodeTrackingInfo? tracking, int season, int episode) =>
    tracking == null ||
    _compareEpisodes(tracking.season, tracking.episode, season, episode) <= 0;

/// Order two episodes: negative when (s1, e1) comes first.
int _compareEpisodes(int s1, int e1, int s2, int e2) =>
    s1 != s2 ? s1.compareTo(s2) : e1.compareTo(e2);

/// The tracking entry whose episode [key] stands for, if a show is at it.
EpisodeTrackingInfo? trackingForKey(AutoDownloadState state, String key) {
  for (final t in state.lastDownloadedEpisodes.values) {
    if (downloadQueueKey(t.showId, t.season, t.episode) == key) return t;
  }
  return null;
}

/// The auto-download record — the queue, the per-show tracking and the
/// activity log — and the writes that fetching and reconciling make to it.
///
/// Holds no state of its own: it reads and writes the notifier's through
/// `read` and `write`, and saves every write (`save`) before returning, so
/// there is still one copy of the state and one place that persists it.
///
/// [state] throws once the notifier is disposed, so check [mounted] after
/// every await before reading it again.
class AutoDownloadLedger {
  AutoDownloadLedger({
    required AutoDownloadState Function() read,
    required void Function(AutoDownloadState state) write,
    required Future<void> Function() save,
    required bool Function() mounted,
    required Future<void> Function(AutoDownloadEvent event) addEvent,
  }) : _read = read,
       _write = write,
       _save = save,
       _mounted = mounted,
       _addEvent = addEvent;

  final AutoDownloadState Function() _read;
  final void Function(AutoDownloadState state) _write;
  final Future<void> Function() _save;
  final bool Function() _mounted;
  final Future<void> Function(AutoDownloadEvent event) _addEvent;

  /// The auto-download state as it is now.
  AutoDownloadState get state => _read();

  /// Whether the notifier is still alive; false after an await means stop.
  bool get mounted => _mounted();

  /// Queue [key] — with [hash], the torrent fetching it, once there is one.
  Future<void> setQueued(String key, String? hash) async {
    final s = state;
    _write(
      s.copyWith(
        downloadQueue: {...s.downloadQueue, key},
        queuedTorrents: hash == null
            ? s.queuedTorrents
            : {...s.queuedTorrents, key: hash},
      ),
    );
    await _save();
  }

  /// Take [key] out of the queue. Saves only when it was there.
  Future<void> releaseQueued(String key) async {
    final s = state;
    if (!s.downloadQueue.contains(key) && !s.queuedTorrents.containsKey(key)) {
      return;
    }
    _write(
      s.copyWith(
        downloadQueue: {...s.downloadQueue}..remove(key),
        queuedTorrents: {...s.queuedTorrents}..remove(key),
      ),
    );
    await _save();
  }

  /// Record [tracking] as where [showId] stands.
  Future<void> updateTracking(int showId, EpisodeTrackingInfo tracking) async {
    final s = state;
    final newTracking = Map<int, EpisodeTrackingInfo>.from(
      s.lastDownloadedEpisodes,
    );
    newTracking[showId] = tracking;
    _write(s.copyWith(lastDownloadedEpisodes: newTracking));
    await _save();
  }

  /// Add an entry to the activity log — unless the notifier is gone.
  Future<void> log(
    AutoDownloadEventType type, {
    required int showId,
    required String showName,
    required int season,
    required int episode,
    String? quality,
    required String message,
  }) async {
    if (!mounted) return;
    await _addEvent(
      AutoDownloadEvent(
        timestamp: DateTime.now(),
        type: type,
        showId: showId,
        showName: showName,
        season: season,
        episode: episode,
        quality: quality,
        message: message,
      ),
    );
  }
}
