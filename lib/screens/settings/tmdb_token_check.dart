import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/tmdb_api_service.dart';
import '../../utils/error_messages.dart';

/// Builds the TMDB client a pasted token is checked with.
///
/// The app's `tmdbApiServiceProvider` is bound to the token already saved,
/// and a pasted token is checked *before* it is saved — saving first would
/// send every open screen off to reload with a token that may be wrong. So
/// the check gets a client of its own. A provider, so tests can hand the
/// check a fake service instead of the network.
final tmdbTokenCheckServiceProvider =
    Provider<TmdbApiService Function(String token)>(
      (ref) =>
          (token) => TmdbApiService(accessToken: token),
    );

enum TmdbTokenVerdict {
  /// TMDB answered with the catalog: the token works.
  accepted,

  /// TMDB refused it. Saving it would leave every catalog row empty.
  rejected,

  /// TMDB could not be asked — offline, timed out, or down. Says nothing
  /// about the token either way.
  unchecked,
}

/// What [checkTmdbToken] found, and what to tell the user about it.
class TmdbTokenCheck {
  const TmdbTokenCheck(this.verdict, [this.message]);

  final TmdbTokenVerdict verdict;

  /// Plain-language explanation for [TmdbTokenVerdict.rejected] and
  /// [TmdbTokenVerdict.unchecked]; null when accepted.
  final String? message;
}

/// Asks TMDB whether [token] works by loading the first page of trending
/// shows — the request the Home screen opens with, so "accepted" means the
/// catalog will actually load.
Future<TmdbTokenCheck> checkTmdbToken(
  TmdbApiService Function(String token) client,
  String token,
) async {
  try {
    await client(token).getTrendingShows();
    return const TmdbTokenCheck(TmdbTokenVerdict.accepted);
  } catch (e) {
    final kind = classifyFailure(e);
    if (kind == FailureKind.unauthorized) {
      return const TmdbTokenCheck(
        TmdbTokenVerdict.rejected,
        'TMDB didn\'t accept this token. Copy the "API Read Access Token" '
        'again — all of it — from your TMDB API settings.',
      );
    }
    // Only the connection-shaped failures have a useful sentence of their
    // own; "TMDB doesn't have TMDB any more" would not be one.
    final why =
        kind == FailureKind.offline ||
            kind == FailureKind.timeout ||
            kind == FailureKind.serviceDown
        ? friendlyErrorMessage(e)
        : 'Try again in a moment.';
    return TmdbTokenCheck(
      TmdbTokenVerdict.unchecked,
      'Couldn\'t check the token with TMDB. $why',
    );
  }
}
