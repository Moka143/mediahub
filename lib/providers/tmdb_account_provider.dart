import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/tmdb_account_service.dart';
import 'settings_provider.dart';

// New v4 storage keys.
const _accessTokenKey = 'tmdb_v4_access_token';
const _accountIdKey = 'tmdb_v4_account_id';
const _accountKey = 'tmdb_v4_account';

// Legacy v3 keys we clean up on first launch under v4.
const _legacySessionKey = 'tmdb_session_id';
const _legacyAccountKey = 'tmdb_account';

/// Persistent TMDB session for the signed-in user (v4 model).
///
/// `accessToken` is a v4 User Access Token returned by the OAuth flow —
/// it identifies the user and authenticates every subsequent request
/// (catalog reads, favorites, watchlist) via `Authorization: Bearer`.
class TmdbSession {
  TmdbSession({
    required this.accessToken,
    required this.accountId,
    required this.account,
  });

  final String accessToken;
  final int accountId;
  final TmdbAccount account;

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'account_id': accountId,
    'account': account.toJson(),
  };
}

/// Service used for the OAuth dance + account-scoped reads/writes. When a
/// user is signed in, the Bearer is their user token; otherwise it falls
/// back to the bundled/user read access token via
/// [effectiveTmdbAccessTokenProvider].
final tmdbAccountServiceProvider = Provider<TmdbAccountService>((ref) {
  final session = ref.watch(tmdbSessionProvider);
  final String token =
      session?.accessToken ?? ref.watch(effectiveTmdbAccessTokenProvider);
  return TmdbAccountService(accessToken: token);
});

final tmdbSessionProvider = NotifierProvider<TmdbSessionNotifier, TmdbSession?>(
  TmdbSessionNotifier.new,
);

/// True when there's a stored TMDB user session — used to gate sync UI.
final isTmdbSignedInProvider = Provider<bool>(
  (ref) => ref.watch(tmdbSessionProvider) != null,
);

class TmdbSessionNotifier extends Notifier<TmdbSession?> {
  @override
  TmdbSession? build() {
    final prefs = ref.watch(sharedPreferencesProvider);

    // One-time migration: drop legacy v3 session_id + account if present.
    // v3 sessions can't be converted to v4 access tokens — user needs to
    // sign in again.
    if (prefs.containsKey(_legacySessionKey) ||
        prefs.containsKey(_legacyAccountKey)) {
      debugPrint(
        '[TmdbSession] Dropping legacy v3 session — please re-sign-in '
        'via v4 OAuth.',
      );
      prefs.remove(_legacySessionKey);
      prefs.remove(_legacyAccountKey);
    }

    final token = prefs.getString(_accessTokenKey);
    final accountId = prefs.getInt(_accountIdKey);
    final accJson = prefs.getString(_accountKey);
    if (token == null || accountId == null || accJson == null) return null;
    try {
      final acc = TmdbAccount.fromJson(
        jsonDecode(accJson) as Map<String, dynamic>,
      );
      return TmdbSession(
        accessToken: token,
        accountId: accountId,
        account: acc,
      );
    } catch (_) {
      return null;
    }
  }

  /// Begin sign-in: request a v4 token, open the approval URL in the
  /// browser. The UI then waits for the user to come back and click
  /// "I've approved it" before calling [completeSignIn].
  Future<String> beginSignIn() async {
    final svc = ref.read(tmdbAccountServiceProvider);
    final token = await svc.createRequestToken();
    final url = Uri.parse(svc.authorizeUrl(token));
    await launchUrl(url, mode: LaunchMode.externalApplication);
    return token;
  }

  /// Finish sign-in after the user has approved the token in their browser.
  /// Exchanges the request token for a user access token, fetches the
  /// account profile (including the v3 integer account id needed for
  /// `/3/account/{id}/...` endpoints), and persists everything.
  Future<void> completeSignIn(String approvedRequestToken) async {
    // OAuth itself runs with the app/read token (Bearer). The user isn't
    // signed in yet, so tmdbAccountServiceProvider already has the right
    // Bearer.
    final svc = ref.read(tmdbAccountServiceProvider);
    final accessToken = await svc.createAccessToken(approvedRequestToken);

    // Build a fresh service authenticated as the user to look up their
    // v3 integer account id — TMDB v4's response gives back a v4-style
    // string id that doesn't fit /3/account/{int}/... endpoints.
    final userSvc = TmdbAccountService(accessToken: accessToken);
    final account = await userSvc.getAccount();

    final session = TmdbSession(
      accessToken: accessToken,
      accountId: account.id,
      account: account,
    );
    state = session;

    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_accessTokenKey, accessToken);
    await prefs.setInt(_accountIdKey, account.id);
    await prefs.setString(_accountKey, jsonEncode(account.toJson()));
  }

  /// Sign out: best-effort revoke on the TMDB side, then drop locally.
  Future<void> signOut() async {
    final session = state;
    if (session != null) {
      // Use a service authenticated as the user (Bearer = the user's own
      // token) to revoke that same token. Best-effort.
      final userSvc = TmdbAccountService(accessToken: session.accessToken);
      // ignore: unawaited_futures
      userSvc.deleteAccessToken(session.accessToken);
    }
    state = null;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_accountIdKey);
    await prefs.remove(_accountKey);
  }
}
