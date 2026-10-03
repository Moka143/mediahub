import 'package:intl/intl.dart';

/// Utility class for formatting values for display
class Formatters {
  Formatters._();

  /// Format bytes to human-readable string (KB, MB, GB, TB)
  static String formatBytes(int bytes, {int decimals = 2}) {
    if (bytes <= 0) return '0 B';

    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var i = 0;
    double size = bytes.toDouble();

    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }

    return '${size.toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  /// Format bytes with per-tier precision: whole bytes, one decimal for
  /// KB/MB, two for GB, and no TB tier.
  ///
  /// Distinct from [formatBytes], which applies one fixed decimal count to
  /// every tier and rolls over to TB/PB. Kept separate because no `decimals`
  /// value reproduces this shape, and changing it would visibly alter file
  /// sizes across the library and episode screens.
  static String formatBytesCompact(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Format bytes per second to speed string
  static String formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0 B/s';
    return '${formatBytes(bytesPerSecond)}/s';
  }

  /// Format seconds to human-readable duration (1d 2h 3m 4s)
  static String formatDuration(int seconds) {
    if (seconds <= 0) return '∞';
    if (seconds == 8640000) return '∞'; // qBittorrent uses this for unknown ETA

    final duration = Duration(seconds: seconds);
    final days = duration.inDays;
    final hours = duration.inHours.remainder(24);
    final minutes = duration.inMinutes.remainder(60);
    final secs = duration.inSeconds.remainder(60);

    final parts = <String>[];
    if (days > 0) parts.add('${days}d');
    if (hours > 0) parts.add('${hours}h');
    if (minutes > 0) parts.add('${minutes}m');
    if (secs > 0 && days == 0) parts.add('${secs}s');

    return parts.isEmpty ? '0s' : parts.join(' ');
  }

  /// Format a playback position as `MM:SS`, or `HH:MM:SS` past the hour.
  ///
  /// Distinct from [formatDuration]: that one takes whole seconds and renders
  /// a coarse `1h 5m 30s` for torrent ETAs. This is the zero-padded clock
  /// form the player and progress models use — 90 seconds is `01:30` here and
  /// `1m 30s` there.
  static String formatPlaybackDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  /// Canonical `S01E02` episode code.
  ///
  /// Several of these strings are used as persistence keys (watch progress,
  /// the auto-download queue, calendar lookups), so every producer must agree
  /// byte for byte — a divergence reads as a cache miss, not a typo.
  static String episodeCode(int season, int episode) =>
      'S${season.toString().padLeft(2, '0')}'
      'E${episode.toString().padLeft(2, '0')}';

  /// [episodeCode] for optional components, null when either is missing.
  static String? episodeCodeOrNull(int? season, int? episode) =>
      season == null || episode == null ? null : episodeCode(season, episode);

  /// Whole calendar days from [from]'s date to [to]'s date.
  ///
  /// Tomorrow is 1 whatever the time of day, and a daylight-saving change in
  /// between does not shave a day off — both of which `difference().inDays`
  /// on local timestamps gets wrong (an episode airing tomorrow read "Today"
  /// every evening). Negative when [to] is earlier.
  static int calendarDaysBetween(DateTime from, DateTime to) {
    final a = DateTime.utc(from.year, from.month, from.day);
    final b = DateTime.utc(to.year, to.month, to.day);
    return b.difference(a).inDays;
  }

  /// Format progress (0.0 to 1.0) to percentage string
  static String formatProgress(double progress, {int decimals = 1}) {
    return '${(progress * 100).toStringAsFixed(decimals)}%';
  }

  /// Format Unix timestamp to date string
  static String formatDate(int timestamp) {
    if (timestamp <= 0) return 'Unknown';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return DateFormat('MMM d, yyyy HH:mm').format(date);
  }

  /// Format Unix timestamp to relative time (e.g., "2 hours ago")
  static String formatRelativeTime(int timestamp) {
    if (timestamp <= 0) return 'Unknown';

    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 365) {
      final years = (difference.inDays / 365).floor();
      return '$years ${years == 1 ? 'year' : 'years'} ago';
    } else if (difference.inDays > 30) {
      final months = (difference.inDays / 30).floor();
      return '$months ${months == 1 ? 'month' : 'months'} ago';
    } else if (difference.inDays > 0) {
      return '${difference.inDays} ${difference.inDays == 1 ? 'day' : 'days'} ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} ${difference.inHours == 1 ? 'hour' : 'hours'} ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} ${difference.inMinutes == 1 ? 'minute' : 'minutes'} ago';
    } else {
      return 'Just now';
    }
  }

  /// Format ratio (e.g., 1.5 -> "1.50")
  static String formatRatio(double ratio) {
    if (ratio < 0) return '∞';
    return ratio.toStringAsFixed(2);
  }
}
