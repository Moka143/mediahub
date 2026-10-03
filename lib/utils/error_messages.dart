import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// What kind of failure an error is, as far as the person looking at the
/// screen is concerned. Drives both the wording and which way out to offer.
enum FailureKind {
  /// No network, DNS failure, connection refused or reset.
  offline,

  /// The request was sent but nothing came back in time.
  timeout,

  /// The service rejected our credentials (TMDB token, qBittorrent login).
  unauthorized,

  /// The thing asked for does not exist.
  notFound,

  /// The service answered with a server error.
  serviceDown,

  /// Anything else.
  unknown,
}

/// A failure from one of the app's HTTP services that already knows what
/// went wrong — implemented by the TMDB, EZTV and Torrentio exceptions.
///
/// Classifying by these fields rather than by the exception's text is what
/// lets a screen tell "your token was rejected" (go to Settings) from "you
/// are offline" (try again): both used to arrive as one flattened string.
abstract interface class ServiceFailure {
  /// The HTTP status the service answered with, when it answered at all.
  int? get statusCode;

  /// No usable connection: DNS, refused, reset, unreachable.
  bool get isNetwork;

  /// The request went out but no answer came back in time.
  bool get isTimeout;
}

/// The shared shape of the app's HTTP service exceptions: a message for the
/// log plus the [ServiceFailure] fields a screen classifies by.
///
/// TMDB, EZTV and Torrentio each had a copy of this class body and of the
/// [DioException] mapping below.
abstract class HttpServiceException implements Exception, ServiceFailure {
  HttpServiceException(
    this.message, {
    this.statusCode,
    this.isNetwork = false,
    this.isTimeout = false,
  });

  /// [message] plus what [e] says about the failure.
  HttpServiceException.fromDio(this.message, DioException e)
    : statusCode = e.response?.statusCode,
      isNetwork =
          e.type == DioExceptionType.connectionError ||
          e.error is SocketException ||
          e.error is HandshakeException,
      isTimeout = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => true,
        _ => false,
      };

  final String message;

  @override
  final int? statusCode;

  @override
  final bool isNetwork;

  @override
  final bool isTimeout;

  /// Prefix for [toString], e.g. `TmdbApiException`.
  String get kind;

  @override
  String toString() => '$kind: $message';
}

final RegExp _statusInText = RegExp(r'status code of (\d{3})');

/// Classify [error] without looking at its exact type more than necessary.
///
/// A [ServiceFailure] says what it is. Anything else that wraps the
/// underlying [DioException] keeps its text, so the text is consulted when
/// the type is not directly recognisable.
FailureKind classifyFailure(Object error) {
  if (error is ServiceFailure) {
    final status = error.statusCode;
    if (status != null) return _fromStatus(status);
    if (error.isTimeout) return FailureKind.timeout;
    if (error.isNetwork) return FailureKind.offline;
    return FailureKind.unknown;
  }
  if (error is TimeoutException) return FailureKind.timeout;
  if (error is SocketException || error is HandshakeException) {
    return FailureKind.offline;
  }
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return FailureKind.timeout;
      case DioExceptionType.connectionError:
        return FailureKind.offline;
      case DioExceptionType.badResponse:
        return _fromStatus(error.response?.statusCode);
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        if (error.error is SocketException) return FailureKind.offline;
        return FailureKind.unknown;
    }
  }

  // Wrapped errors: classify by the text they carry.
  final text = error.toString();
  final status = _statusInText.firstMatch(text);
  if (status != null) {
    return _fromStatus(int.tryParse(status.group(1)!));
  }
  final lower = text.toLowerCase();
  if (lower.contains('socketexception') ||
      lower.contains('connection error') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable')) {
    return FailureKind.offline;
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return FailureKind.timeout;
  }
  if (lower.contains('invalid api key') ||
      lower.contains('authentication failed') ||
      lower.contains('unauthorized')) {
    return FailureKind.unauthorized;
  }
  return FailureKind.unknown;
}

FailureKind _fromStatus(int? status) {
  if (status == null) return FailureKind.unknown;
  if (status == 401 || status == 403) return FailureKind.unauthorized;
  if (status == 404) return FailureKind.notFound;
  if (status >= 500) return FailureKind.serviceDown;
  return FailureKind.unknown;
}

/// One plain sentence describing [error] for the screen, never the raw
/// exception text.
///
/// [subject] names what failed to load, for example `'shows'` or
/// `'this movie'`, and is woven into the generic cases.
String friendlyErrorMessage(Object error, {String subject = 'this'}) {
  switch (classifyFailure(error)) {
    case FailureKind.offline:
      return "Couldn't reach the internet. Check your connection and try again.";
    case FailureKind.timeout:
      return 'The server took too long to answer. Try again in a moment.';
    case FailureKind.unauthorized:
      return 'Your TMDB token was rejected. Check it in Settings → Connection.';
    case FailureKind.notFound:
      return "TMDB doesn't have $subject any more.";
    case FailureKind.serviceDown:
      return 'TMDB is having trouble right now. Try again shortly.';
    case FailureKind.unknown:
      return "Couldn't load $subject. Try again.";
  }
}

/// Whether the useful way out of [error] is Settings rather than Retry.
bool failureNeedsSettings(Object error) =>
    classifyFailure(error) == FailureKind.unauthorized;
