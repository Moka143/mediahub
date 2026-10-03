/// Checks for the values typed into Settings. Each returns the message to
/// show under the field, or null when the value is fine.
library;

/// A TCP port: 1–65535.
String? validatePort(String text) {
  final port = int.tryParse(text.trim());
  if (port == null || port < 1 || port > 65535) {
    return 'Enter a port number from 1 to 65535.';
  }
  return null;
}

/// The host qBittorrent's Web UI answers on — a name or an address, nothing
/// else. The app builds `http://<host>:<port>` itself, so a pasted URL or a
/// port here produces an address nothing listens on.
String? validateHost(String text) {
  final host = text.trim();
  if (host.isEmpty) return 'Enter a host, such as localhost.';
  if (host.contains('://') || host.contains('/')) {
    return 'Enter just the host — leave out http:// and any path.';
  }
  if (host.contains(RegExp(r'\s'))) return 'A host has no spaces.';
  // A bracketed IPv6 address carries colons legitimately; anything else
  // with one is a host and a port typed together.
  final isBracketedIpv6 = host.startsWith('[') && host.endsWith(']');
  if (host.contains(':') && !isBracketedIpv6) {
    return 'Put the port in the Port field, not after the host.';
  }
  return null;
}

/// The most a speed limit field accepts, in KB/s — about 10 GB/s, far above
/// any real connection, and well inside the engines' integer range.
const int maxSpeedLimitKbps = 10000000;

/// A speed limit in KB/s. Empty and 0 both mean "no limit".
String? validateSpeedLimit(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final value = int.tryParse(trimmed);
  if (value == null || value < 0) {
    return 'Enter a whole number of KB/s, or leave it empty for no limit.';
  }
  if (value > maxSpeedLimitKbps) return 'That is more than any connection.';
  return null;
}

/// The bytes-per-second value a speed limit field means. Empty is 0, which
/// the engines read as "no limit".
int speedLimitBytes(String text) => (int.tryParse(text.trim()) ?? 0) * 1024;

/// The KB/s text a saved bytes-per-second limit shows as. 0 shows empty —
/// "no limit" — rather than a 0 that looks like "nothing at all".
String speedLimitText(int bytesPerSecond) =>
    bytesPerSecond > 0 ? '${bytesPerSecond ~/ 1024}' : '';

/// Whether [text] has the shape of a TMDB v4 Read Access Token: a JWT,
/// which always begins `eyJ` (base64 of `{"`) and has three dot-separated
/// parts. The old 32-character v3 API key does not work as a Bearer token.
String? tmdbTokenFormatError(String text) {
  final token = text.trim();
  if (token.isEmpty) return 'Paste your TMDB token first.';
  if (!token.startsWith('eyJ') || token.split('.').length != 3) {
    return 'That isn\'t a TMDB token. Copy the "API Read Access Token" — '
        'the long one that starts with eyJ… — from your TMDB API settings.';
  }
  return null;
}
