import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/tmdb_account_service.dart';
import 'settings_provider.dart';

const _sessionKey = 'tmdb_session_id';
const _accountKey = 'tmdb_account';

/// Persistent TMDB session for the signed-in user.
class TmdbSession {
  TmdbSession({required this.sessionId, required this.account});

  final String sessionId;
  final TmdbAccount account;

  Map<String, dynamic> toJson() => {
    'session_id': sessionId,
    'account': account.toJson(),
  };

  static TmdbSession? fromJson(Map<String, dynamic> json) {
    final sid = json['session_id'] as String?;
    final acc = json['account'] as Map<String, dynamic>?;
    if (sid == null || acc == null) return null;
    return TmdbSession(sessionId: sid, account: TmdbAccount.fromJson(acc));
  }
}

final tmdbAccountServiceProvider = Provider<TmdbAccountService>((ref) {
  final apiKey = ref.watch(settingsProvider).tmdbApiKey;
  return TmdbAccountService(apiKey: apiKey);
});

final tmdbSessionProvider =
    NotifierProvider<TmdbSessionNotifier, TmdbSession?>(
      TmdbSessionNotifier.new,
    );

/// True when there's a stored TMDB session — used to gate sync UI.
final isTmdbSignedInProvider = Provider<bool>(
  (ref) => ref.watch(tmdbSessionProvider) != null,
);

class TmdbSessionNotifier extends Notifier<TmdbSession?> {
  @override
  TmdbSession? build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final sid = prefs.getString(_sessionKey);
    final accJson = prefs.getString(_accountKey);
    if (sid == null || accJson == null) return null;
    try {
      final acc = TmdbAccount.fromJson(
        jsonDecode(accJson) as Map<String, dynamic>,
      );
      return TmdbSession(sessionId: sid, account: acc);
    } catch (_) {
      return null;
    }
  }

  /// Begin sign-in: returns the request_token + browser-launch result so
  /// the UI can show a "I've approved it" button before [completeSignIn].
  Future<String> beginSignIn() async {
    final svc = ref.read(tmdbAccountServiceProvider);
    final token = await svc.createRequestToken();
    final url = Uri.parse(svc.authorizeUrl(token));
    await launchUrl(url, mode: LaunchMode.externalApplication);
    return token;
  }

  /// Finish sign-in after the user has approved the token in their browser.
  Future<void> completeSignIn(String approvedRequestToken) async {
    final svc = ref.read(tmdbAccountServiceProvider);
    final sid = await svc.createSession(approvedRequestToken);
    final account = await svc.getAccount(sid);
    final session = TmdbSession(sessionId: sid, account: account);
    state = session;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_sessionKey, sid);
    await prefs.setString(_accountKey, jsonEncode(account.toJson()));
  }

  Future<void> signOut() async {
    final session = state;
    if (session != null) {
      // Best-effort revoke; don't block local sign-out on it.
      // ignore: unawaited_futures
      ref.read(tmdbAccountServiceProvider).deleteSession(session.sessionId);
    }
    state = null;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.remove(_sessionKey);
    await prefs.remove(_accountKey);
  }
}
