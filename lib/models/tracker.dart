/// Represents a tracker for a torrent
class Tracker {
  final String url;
  final int status;
  final int tier;
  final int numPeers;
  final int numSeeds;
  final int numLeeches;
  final int numDownloaded;
  final String msg;

  Tracker({
    required this.url,
    required this.status,
    required this.tier,
    required this.numPeers,
    required this.numSeeds,
    required this.numLeeches,
    required this.numDownloaded,
    required this.msg,
  });

  factory Tracker.fromJson(Map<String, dynamic> json) {
    return Tracker(
      url: json['url'] as String? ?? '',
      status: json['status'] as int? ?? 0,
      tier: json['tier'] as int? ?? 0,
      numPeers: json['num_peers'] as int? ?? 0,
      numSeeds: json['num_seeds'] as int? ?? 0,
      numLeeches: json['num_leeches'] as int? ?? 0,
      numDownloaded: json['num_downloaded'] as int? ?? 0,
      msg: json['msg'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'status': status,
      'tier': tier,
      'num_peers': numPeers,
      'num_seeds': numSeeds,
      'num_leeches': numLeeches,
      'num_downloaded': numDownloaded,
      'msg': msg,
    };
  }

  /// Get status as human-readable string
  String get statusText {
    switch (status) {
      case 0:
        return 'Disabled';
      case 1:
        return 'Not contacted';
      case 2:
        return 'Working';
      case 3:
        return 'Updating';
      case 4:
        return 'Not working';
      default:
        return 'Unknown';
    }
  }

  /// Check if tracker is working
  bool get isWorking => status == 2;

  /// Check if tracker has an error
  bool get hasError => status == 4;

  /// Get the tracker host
  String get host {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (e) {
      return url;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Tracker &&
          runtimeType == other.runtimeType &&
          url == other.url;

  @override
  int get hashCode => url.hashCode;
}
