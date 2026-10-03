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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Tracker && runtimeType == other.runtimeType && url == other.url;

  @override
  int get hashCode => url.hashCode;
}
