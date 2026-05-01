import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/movie.dart';
import '../models/show.dart';
import '../services/tmdb_account_service.dart';
import 'shows_provider.dart';
import 'settings_provider.dart';
import 'tmdb_account_provider.dart';

const _watchlistTvKey = 'watchlist_tv';
const _watchlistMoviesKey = 'watchlist_movies';

/// Watchlist state — TV shows and movies the user wants to watch later.
/// Mirrors the same shape as favorites and rides the same TMDB account.
class WatchlistState {
  const WatchlistState({
    this.showIds = const {},
    this.movieIds = const {},
    this.isSyncing = false,
    this.error,
  });

  final Set<int> showIds;
  final Set<int> movieIds;
  final bool isSyncing;
  final String? error;

  WatchlistState copyWith({
    Set<int>? showIds,
    Set<int>? movieIds,
    bool? isSyncing,
    String? error,
  }) {
    return WatchlistState(
      showIds: showIds ?? this.showIds,
      movieIds: movieIds ?? this.movieIds,
      isSyncing: isSyncing ?? this.isSyncing,
      error: error,
    );
  }

  bool hasShow(int id) => showIds.contains(id);
  bool hasMovie(int id) => movieIds.contains(id);
}

class WatchlistNotifier extends Notifier<WatchlistState> {
  @override
  WatchlistState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    Set<int> tv = const {};
    Set<int> movies = const {};
    try {
      final s = prefs.getString(_watchlistTvKey);
      if (s != null) tv = (jsonDecode(s) as List<dynamic>).cast<int>().toSet();
    } catch (_) {}
    try {
      final s = prefs.getString(_watchlistMoviesKey);
      if (s != null) {
        movies = (jsonDecode(s) as List<dynamic>).cast<int>().toSet();
      }
    } catch (_) {}
    return WatchlistState(showIds: tv, movieIds: movies);
  }

  TmdbAccountService get _accountService =>
      ref.read(tmdbAccountServiceProvider);
  TmdbSession? get _session => ref.read(tmdbSessionProvider);

  Future<void> _saveTv() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_watchlistTvKey, jsonEncode(state.showIds.toList()));
  }

  Future<void> _saveMovies() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(
      _watchlistMoviesKey,
      jsonEncode(state.movieIds.toList()),
    );
  }

  Future<void> toggleShow(int id) async {
    final on = !state.showIds.contains(id);
    final newIds = Set<int>.from(state.showIds);
    on ? newIds.add(id) : newIds.remove(id);
    state = state.copyWith(showIds: newIds);
    await _saveTv();
    _push(TmdbMediaType.tv, id, on);
  }

  Future<void> toggleMovie(int id) async {
    final on = !state.movieIds.contains(id);
    final newIds = Set<int>.from(state.movieIds);
    on ? newIds.add(id) : newIds.remove(id);
    state = state.copyWith(movieIds: newIds);
    await _saveMovies();
    _push(TmdbMediaType.movie, id, on);
  }

  void _push(TmdbMediaType type, int id, bool on) {
    final s = _session;
    if (s == null) return;
    () async {
      try {
        await _accountService.setWatchlist(
          accountId: s.account.id,
          sessionId: s.sessionId,
          mediaType: type,
          mediaId: id,
          watchlist: on,
        );
      } catch (e) {
        debugPrint('TMDB watchlist push failed for $type:$id ($on): $e');
      }
    }();
  }

  /// Pull authoritative watchlist from TMDB and replace local state.
  Future<void> syncFromTmdb({bool pushLocalFirst = false}) async {
    final s = _session;
    if (s == null) return;
    state = state.copyWith(isSyncing: true, error: null);
    try {
      if (pushLocalFirst) {
        for (final id in state.showIds) {
          try {
            await _accountService.setWatchlist(
              accountId: s.account.id,
              sessionId: s.sessionId,
              mediaType: TmdbMediaType.tv,
              mediaId: id,
              watchlist: true,
            );
          } catch (_) {}
        }
        for (final id in state.movieIds) {
          try {
            await _accountService.setWatchlist(
              accountId: s.account.id,
              sessionId: s.sessionId,
              mediaType: TmdbMediaType.movie,
              mediaId: id,
              watchlist: true,
            );
          } catch (_) {}
        }
      }

      final tv = await _accountService.getWatchlistShowIds(
        accountId: s.account.id,
        sessionId: s.sessionId,
      );
      final movies = await _accountService.getWatchlistMovieIds(
        accountId: s.account.id,
        sessionId: s.sessionId,
      );
      state = state.copyWith(
        showIds: tv,
        movieIds: movies,
        isSyncing: false,
      );
      await _saveTv();
      await _saveMovies();
    } catch (e) {
      state = state.copyWith(isSyncing: false, error: e.toString());
    }
  }
}

final watchlistProvider =
    NotifierProvider<WatchlistNotifier, WatchlistState>(WatchlistNotifier.new);

final isOnWatchlistProvider = Provider.family<bool, int>((ref, id) {
  return ref.watch(watchlistProvider).showIds.contains(id);
});

final isMovieOnWatchlistProvider = Provider.family<bool, int>((ref, id) {
  return ref.watch(watchlistProvider).movieIds.contains(id);
});

final watchlistShowsProvider = FutureProvider<List<Show>>((ref) async {
  final wl = ref.watch(watchlistProvider);
  final tmdb = ref.read(tmdbApiServiceProvider);
  if (wl.showIds.isEmpty) return [];
  final out = <Show>[];
  for (final id in wl.showIds) {
    try {
      out.add(await tmdb.getShowDetails(id));
    } catch (_) {}
  }
  return out;
});

final watchlistMoviesProvider = FutureProvider<List<Movie>>((ref) async {
  final wl = ref.watch(watchlistProvider);
  final tmdb = ref.read(tmdbApiServiceProvider);
  if (wl.movieIds.isEmpty) return [];
  final out = <Movie>[];
  for (final id in wl.movieIds) {
    try {
      out.add(await tmdb.getMovieDetails(id));
    } catch (_) {}
  }
  return out;
});
