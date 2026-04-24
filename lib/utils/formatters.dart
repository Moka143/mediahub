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

  /// Format progress (0.0 to 1.0) to percentage string
  static String formatProgress(double progress) {
    return '${(progress * 100).toStringAsFixed(1)}%';
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

  /// Truncate string with ellipsis if too long
  static String truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength - 3)}...';
  }
}
