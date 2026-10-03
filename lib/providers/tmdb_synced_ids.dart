import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/movie.dart';
import '../models/show.dart';
import '../services/app_logger.dart';
import '../services/json_prefs_store.dart';
import '../services/tmdb_account_service.dart';
import '../services/tmdb_api_service.dart';
import '../utils/error_messages.dart';
import 'settings_provider.dart';
import 'tmdb_account_provider.dart';

/// A TMDB account list that the app mirrors locally — a set of show ids and
/// a set of movie ids, kept in step with the signed-in account.
enum TmdbAccountList {
  favorites(
    showsKey: 'favorite_shows',
    moviesKey: 'favorite_movies',
    pendingKey: 'favorites_pending_tmdb',
    logTag: 'Favorites',
  ),
  watchlist(
    showsKey: 'watchlist_tv',
    moviesKey: 'watchlist_movies',
    pendingKey: 'watchlist_pending_tmdb',
    logTag: 'Watchlist',
  );

  const TmdbAccountList({
    required this.showsKey,
    required this.moviesKey,
    required this.pendingKey,
    required this.logTag,
  });

  /// Prefs keys. Stable: they hold what older builds stored.
  final String showsKey;
  final String moviesKey;

  /// Where changes TMDB has not confirmed yet are queued.
  final String pendingKey;

  final String logTag;

  /// Add [id] to, or remove it from, this list on TMDB.
  Future<void> push(
    TmdbAccountService account,
    int accountId,
    TmdbMediaType type,
    int id, {
    required bool on,
  }) => switch (this) {
    favorites => account.setFavorite(
      accountId: accountId,
      mediaType: type,
      mediaId: id,
      favorite: on,
    ),
    watchlist => account.setWatchlist(
      accountId: accountId,
      mediaType: type,
      mediaId: id,
      watchlist: on,
    ),
  };

  /// Every id of [type] on this list on TMDB.
  Future<Set<int>> fetch(
    TmdbAccountService account,
    int accountId,
    TmdbMediaType type,
  ) => switch ((this, type)) {
    (favorites, TmdbMediaType.tv) => account.getFavoriteShowIds(
      accountId: accountId,
    ),
    (favorites, TmdbMediaType.movie) => account.getFavoriteMovieIds(
      accountId: accountId,
    ),
    (watchlist, TmdbMediaType.tv) => account.getWatchlistShowIds(
      accountId: accountId,
    ),
    (watchlist, TmdbMediaType.movie) => account.getWatchlistMovieIds(
      accountId: accountId,
    ),
  };
}

/// A change made on this device that TMDB has not confirmed yet.
@immutable
class PendingTmdbChange {
  const PendingTmdbChange(this.type, this.id, {required this.on});

  /// Decode one queued change; throws on anything malformed, which the
  /// store turns into "skip this entry".
  factory PendingTmdbChange.fromJson(Object? json) {
    final map = json! as Map<String, dynamic>;
    final type = switch (map['type']) {
      'tv' => TmdbMediaType.tv,
      'movie' => TmdbMediaType.movie,
      final other => throw FormatException('Unknown media type: $other'),
    };
    return PendingTmdbChange(type, map['id'] as int, on: map['on'] as bool);
  }

  final TmdbMediaType type;
  final int id;

  /// True to add to the list, false to remove from it.
  final bool on;

  /// One pending change per item: a later toggle replaces an earlier one.
  String get key => '${type.api}:$id';

  Map<String, dynamic> toJson() => {'type': type.api, 'id': id, 'on': on};
}

/// What a [TmdbSyncedIdsNotifier.syncFromTmdb] call came to.
enum TmdbSyncOutcome {
  /// The local lists now match TMDB, plus any changes still pending.
  synced,

  /// Nobody is signed in; nothing was attempted.
  signedOut,

  /// TMDB could not be read. The local lists are unchanged.
  failed,
}

/// The result of a sync, for the screen that asked for it.
@immutable
class TmdbSyncResult {
  const TmdbSyncResult(this.outcome, {this.pendingChanges = 0, this.error});

  final TmdbSyncOutcome outcome;

  /// Changes made here that still have not reached TMDB — they are kept,
  /// and retried on the next sync.
  final int pendingChanges;

  /// Why it failed, when it did. Never show this directly: see [message].
  final Object? error;

  bool get ok => outcome != TmdbSyncOutcome.failed;

  /// One plain sentence describing a failure for the screen, or null.
  String? get message => error == null
      ? null
      : friendlyErrorMessage(error!, subject: 'your TMDB lists');
}

/// What favorites and the watchlist states share, so one notifier can keep
/// both.
abstract interface class TmdbIdSetsState {
  Set<int> get syncedShowIds;
  Set<int> get syncedMovieIds;
  bool get isSyncing;

  /// A user-facing sentence about the last failed sync, or null.
  String? get error;
}

/// One TMDB account list mirrored locally, for shows and movies alike —
/// the logic favorites and the watchlist used to carry as two hand-written
/// copies.
///
/// - **Local first.** A toggle changes the local set at once and is
///   persisted; the TMDB push follows in the background.
/// - **Nothing lost to a failed push.** While signed in, every toggle is
///   queued (persisted) until TMDB confirms it. A failed push stays queued
///   and is retried on the next sync — the launch sync included — instead
///   of being logged and forgotten. A sync merges the queue over TMDB's
///   answer, so a favorite added offline is no longer replaced by the
///   server's older list at the next launch.
/// - **Failure reported.** [syncFromTmdb] returns a [TmdbSyncResult] (and
///   the state carries a plain-language [TmdbIdSetsState.error]) instead of
///   swallowing it.
abstract class TmdbSyncedIdsNotifier<S extends TmdbIdSetsState>
    extends Notifier<S> {
  /// Which TMDB list this mirrors.
  @protected
  TmdbAccountList get list;

  /// The state for these sets and status. List-specific extras (favorites'
  /// detail caches) are carried over from the current state by the
  /// subclass.
  @protected
  S stateFor({
    required Set<int> shows,
    required Set<int> movies,
    required bool isSyncing,
    String? error,
  });

  late JsonPrefsStore _showStore;
  late JsonPrefsStore _movieStore;
  late JsonPrefsStore _pendingStore;
  Map<String, PendingTmdbChange> _pending = {};

  /// Changes waiting for TMDB, oldest first.
  List<PendingTmdbChange> get pendingChanges => _pending.values.toList();

  /// Read both sets and the pending queue. Call from `build()`.
  ///
  /// A bad value is quarantined rather than read as empty and saved over —
  /// see [JsonPrefsStore].
  @protected
  ({Set<int> shows, Set<int> movies}) loadIds() {
    final prefs = ref.watch(sharedPreferencesProvider);
    _showStore = JsonPrefsStore(prefs, list.showsKey);
    _movieStore = JsonPrefsStore(prefs, list.moviesKey);
    _pendingStore = JsonPrefsStore(prefs, list.pendingKey);
    _pending = {
      for (final change in _pendingStore.readList(PendingTmdbChange.fromJson))
        change.key: change,
    };
    return (
      shows: _showStore.readList((e) => e! as int).toSet(),
      movies: _movieStore.readList((e) => e! as int).toSet(),
    );
  }

  Future<void> _saveSets() async {
    await _showStore.write(state.syncedShowIds.toList());
    await _movieStore.write(state.syncedMovieIds.toList());
  }

  Future<void> _savePending() =>
      _pendingStore.write([for (final c in _pending.values) c.toJson()]);

  /// Put [id] on the list ([on]) or take it off, here and on TMDB.
  @protected
  Future<void> setItem(TmdbMediaType type, int id, {required bool on}) async {
    final shows = {...state.syncedShowIds};
    final movies = {...state.syncedMovieIds};
    final target = type == TmdbMediaType.tv ? shows : movies;
    on ? target.add(id) : target.remove(id);
    state = stateFor(
      shows: shows,
      movies: movies,
      isSyncing: state.isSyncing,
      error: state.error,
    );
    await _saveSets();

    // Signed out, there is nobody to tell. Signing in pushes the whole local
    // list (`syncFromTmdb(pushLocalFirst: true)`).
    final session = ref.read(tmdbSessionProvider);
    if (session == null || !ref.mounted) return;
    final account = ref.read(tmdbAccountServiceProvider);
    final change = PendingTmdbChange(type, id, on: on);
    _pending[change.key] = change;
    await _savePending();
    unawaited(_push(change, account, session.accountId));
  }

  /// Push one change; drop it from the queue only if TMDB took it and no
  /// newer change for the same item replaced it in the meantime.
  Future<bool> _push(
    PendingTmdbChange change,
    TmdbAccountService account,
    int accountId,
  ) async {
    try {
      await list.push(
        account,
        accountId,
        change.type,
        change.id,
        on: change.on,
      );
    } catch (e) {
      AppLog.w(
        '[${list.logTag}] TMDB push ${change.key} (${change.on}) failed, '
        'kept for the next sync: $e',
      );
      return false;
    }
    if (!ref.mounted) return true;
    if (identical(_pending[change.key], change)) {
      _pending.remove(change.key);
      await _savePending();
    }
    return true;
  }

  /// Bring the local lists in line with TMDB.
  ///
  /// First every queued change is pushed again; on sign-in
  /// ([pushLocalFirst]) every local item is pushed too, so nothing on this
  /// device is lost to the pull. Then TMDB's lists are read and **replace**
  /// the local ones — except for changes TMDB still has not confirmed, which
  /// are applied on top and stay queued.
  ///
  /// Never throws: the outcome, and a failure's cause, are in the result,
  /// and a failure also sets the state's `error` sentence.
  Future<TmdbSyncResult> syncFromTmdb({bool pushLocalFirst = false}) async {
    final session = ref.read(tmdbSessionProvider);
    if (session == null) {
      return const TmdbSyncResult(TmdbSyncOutcome.signedOut);
    }
    final account = ref.read(tmdbAccountServiceProvider);
    final accountId = session.accountId;
    state = stateFor(
      shows: state.syncedShowIds,
      movies: state.syncedMovieIds,
      isSyncing: true,
    );

    // ── Push ──────────────────────────────────────────────────────────
    for (final change in pendingChanges) {
      await _push(change, account, accountId);
      if (!ref.mounted) return const TmdbSyncResult(TmdbSyncOutcome.failed);
    }
    if (pushLocalFirst) {
      var queued = false;
      for (final (type, ids) in [
        (TmdbMediaType.tv, state.syncedShowIds.toList()),
        (TmdbMediaType.movie, state.syncedMovieIds.toList()),
      ]) {
        for (final id in ids) {
          final change = PendingTmdbChange(type, id, on: true);
          if (_pending.containsKey(change.key)) continue;
          try {
            await list.push(account, accountId, type, id, on: true);
          } catch (e) {
            // Queued, not skipped: a union that silently drops an item is
            // how a favorite quietly never reaches TMDB.
            AppLog.w('[${list.logTag}] push ${change.key} failed: $e');
            _pending[change.key] = change;
            queued = true;
          }
          if (!ref.mounted) {
            return const TmdbSyncResult(TmdbSyncOutcome.failed);
          }
        }
      }
      if (queued) await _savePending();
    }

    // ── Pull ──────────────────────────────────────────────────────────
    final Set<int> remoteShows;
    final Set<int> remoteMovies;
    try {
      remoteShows = await list.fetch(account, accountId, TmdbMediaType.tv);
      remoteMovies = await list.fetch(account, accountId, TmdbMediaType.movie);
    } catch (e) {
      AppLog.w('[${list.logTag}] TMDB sync failed: $e');
      if (!ref.mounted) {
        return TmdbSyncResult(TmdbSyncOutcome.failed, error: e);
      }
      state = stateFor(
        shows: state.syncedShowIds,
        movies: state.syncedMovieIds,
        isSyncing: false,
        error: friendlyErrorMessage(e, subject: 'your TMDB lists'),
      );
      return TmdbSyncResult(
        TmdbSyncOutcome.failed,
        pendingChanges: _pending.length,
        error: e,
      );
    }
    if (!ref.mounted) return const TmdbSyncResult(TmdbSyncOutcome.failed);

    final shows = {...remoteShows};
    final movies = {...remoteMovies};
    for (final change in _pending.values) {
      final target = change.type == TmdbMediaType.tv ? shows : movies;
      change.on ? target.add(change.id) : target.remove(change.id);
    }
    state = stateFor(shows: shows, movies: movies, isSyncing: false);
    await _saveSets();
    return TmdbSyncResult(
      TmdbSyncOutcome.synced,
      pendingChanges: _pending.length,
    );
  }
}

/// A set of TMDB ids as a value: equal to any other with the same ids in any
/// order. Selecting one of these out of a list's state means a provider
/// rebuilds when the ids change — not on every `isSyncing` flip or detail
/// cache update, each of which used to refetch every title's details.
@immutable
class TmdbIds {
  TmdbIds(Iterable<int> ids) : ids = List.unmodifiable(ids.toSet());

  /// The ids, in the order the list holds them.
  final List<int> ids;

  bool get isEmpty => ids.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is TmdbIds &&
      other.ids.length == ids.length &&
      ids.toSet().containsAll(other.ids);

  @override
  int get hashCode => Object.hashAllUnordered(ids);
}

/// Details for [ids], fetched in parallel — the one implementation behind
/// the favorites and watchlist grids (and the upcoming-episodes strip,
/// which reuses the favorites fetch rather than repeating it).
///
/// A title that fails is left out; if every one fails, the first error is
/// thrown so the screen can say so instead of showing an empty grid.
Future<List<Show>> fetchShowsForIds(TmdbApiService tmdb, TmdbIds ids) =>
    _fetchAll(ids, tmdb.getShowDetails, 'show');

/// Movie twin of [fetchShowsForIds].
Future<List<Movie>> fetchMoviesForIds(TmdbApiService tmdb, TmdbIds ids) =>
    _fetchAll(ids, tmdb.getMovieDetails, 'movie');

Future<List<T>> _fetchAll<T>(
  TmdbIds ids,
  Future<T> Function(int id) fetch,
  String what,
) async {
  if (ids.isEmpty) return <T>[];
  Object? firstError;
  final results = await Future.wait(
    ids.ids.map(
      (id) => fetch(id).then<T?>(
        (value) => value,
        onError: (Object e) {
          AppLog.w('[TMDB] omitting $what $id: $e');
          firstError ??= e;
          return null;
        },
      ),
    ),
  );
  final found = results.whereType<T>().toList();
  final error = firstError;
  if (found.isEmpty && error != null) throw error;
  return found;
}
