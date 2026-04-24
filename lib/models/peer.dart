/// Represents a peer connected to a torrent
class Peer {
  final String ip;
  final int port;
  final String client;
  final double progress;
  final int dlSpeed;
  final int upSpeed;
  final int downloaded;
  final int uploaded;
  final String connection;
  final String flags;
  final String flagsDesc;
  final double relevance;
  final String country;
  final String countryCode;

  Peer({
    required this.ip,
    required this.port,
    required this.client,
    required this.progress,
    required this.dlSpeed,
    required this.upSpeed,
    required this.downloaded,
    required this.uploaded,
    required this.connection,
    required this.flags,
    required this.flagsDesc,
    required this.relevance,
    required this.country,
    required this.countryCode,
  });

  factory Peer.fromJson(String key, Map<String, dynamic> json) {
    return Peer(
      ip: json['ip'] as String? ?? key.split(':').first,
      port: json['port'] as int? ?? 0,
      client: json['client'] as String? ?? 'Unknown',
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      dlSpeed: json['dl_speed'] as int? ?? 0,
      upSpeed: json['up_speed'] as int? ?? 0,
      downloaded: json['downloaded'] as int? ?? 0,
      uploaded: json['uploaded'] as int? ?? 0,
      connection: json['connection'] as String? ?? '',
      flags: json['flags'] as String? ?? '',
      flagsDesc: json['flags_desc'] as String? ?? '',
      relevance: (json['relevance'] as num?)?.toDouble() ?? 0.0,
      country: json['country'] as String? ?? '',
      countryCode: json['country_code'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'ip': ip,
      'port': port,
      'client': client,
      'progress': progress,
      'dl_speed': dlSpeed,
      'up_speed': upSpeed,
      'downloaded': downloaded,
      'uploaded': uploaded,
      'connection': connection,
      'flags': flags,
      'flags_desc': flagsDesc,
      'relevance': relevance,
      'country': country,
      'country_code': countryCode,
    };
  }

  /// Get the full address (ip:port)
  String get address => '$ip:$port';

  /// Check if peer is currently downloading from us
  bool get isDownloading => upSpeed > 0;

  /// Check if peer is currently uploading to us
  bool get isUploading => dlSpeed > 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Peer &&
          runtimeType == other.runtimeType &&
          ip == other.ip &&
          port == other.port;

  @override
  int get hashCode => Object.hash(ip, port);
}
