import 'dart:convert';

// =============================================================================
// ConnectionConfig — parsed from the QR JSON produced by VortexEngine
//
// QR format:
// {
//   "v": 1,
//   "app": "vortexcam",
//   "host": "VortexEngine",
//   "whip":  { "url": "http://192.168.x.x:8080/whip/" },
//   "srt":   { "host": "192.168.x.x", "port": 9000, "latencyMs": 80 },
//   "rtmp":  { "url": "rtmp://192.168.x.x:1935/live/vortexcam" },
//   "video": { "codec": "h264", "w": 1920, "h": 1080, "fps": 60, "maxKbps": 8000 }
// }
// =============================================================================

enum Transport { whip, srt, rtmp }

class WhipConfig {
  final String url;
  const WhipConfig({required this.url});
}

class SrtConfig {
  final String host;
  final int    port;
  final int    latencyMs;
  const SrtConfig({required this.host, required this.port, this.latencyMs = 80});
}

class RtmpConfig {
  final String url;
  const RtmpConfig({required this.url});
}

class VideoConfig {
  final String codec;
  final int    width;
  final int    height;
  final int    fps;
  final int    maxKbps;
  const VideoConfig({
    this.codec   = 'h264',
    this.width   = 1920,
    this.height  = 1080,
    this.fps     = 60,
    this.maxKbps = 8000,
  });
}

class ConnectionConfig {
  final String     host;
  final WhipConfig? whip;
  final SrtConfig?  srt;
  final RtmpConfig? rtmp;
  final VideoConfig video;

  const ConnectionConfig({
    required this.host,
    this.whip,
    this.srt,
    this.rtmp,
    this.video = const VideoConfig(),
  });

  /// Returns the preferred transport in priority order: SRT > WHIP > RTMP
  Transport get preferredTransport {
    if (srt  != null) return Transport.srt;
    if (whip != null) return Transport.whip;
    if (rtmp != null) return Transport.rtmp;
    return Transport.whip;
  }

  bool get hasSrt  => srt  != null;
  bool get hasWhip => whip != null;
  bool get hasRtmp => rtmp != null;

  static ConnectionConfig? tryParse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['app'] != 'vortexcam') return null;

      WhipConfig? whip;
      SrtConfig?  srt;
      RtmpConfig? rtmp;

      if (j['whip'] is Map) {
        final url = (j['whip']['url'] ?? '').toString();
        if (url.isNotEmpty) whip = WhipConfig(url: url);
      }
      if (j['srt'] is Map) {
        final host = (j['srt']['host'] ?? '').toString();
        final port = (j['srt']['port'] as num?)?.toInt() ?? 9000;
        final lat  = (j['srt']['latencyMs'] as num?)?.toInt() ?? 80;
        if (host.isNotEmpty) srt = SrtConfig(host: host, port: port, latencyMs: lat);
      }
      if (j['rtmp'] is Map) {
        final url = (j['rtmp']['url'] ?? '').toString();
        if (url.isNotEmpty) rtmp = RtmpConfig(url: url);
      }

      if (whip == null && srt == null && rtmp == null) return null;

      final v = j['video'] is Map ? j['video'] as Map : <String, dynamic>{};
      final video = VideoConfig(
        codec:   (v['codec'] ?? 'h264').toString(),
        width:   (v['w']  as num?)?.toInt() ?? 1920,
        height:  (v['h']  as num?)?.toInt() ?? 1080,
        fps:     (v['fps'] as num?)?.toInt() ?? 60,
        maxKbps: (v['maxKbps'] as num?)?.toInt() ?? 8000,
      );

      return ConnectionConfig(
        host:  (j['host'] ?? 'VortexEngine').toString(),
        whip:  whip,
        srt:   srt,
        rtmp:  rtmp,
        video: video,
      );
    } catch (_) {
      return null;
    }
  }

  /// Create a WHIP-only config from a manual URL entry
  static ConnectionConfig fromWhipUrl(String url) => ConnectionConfig(
    host: 'Manual',
    whip: WhipConfig(url: url),
  );

  /// Create an SRT config from manual IP entry
  static ConnectionConfig fromSrtIp(String ip, {int port = 9000}) => ConnectionConfig(
    host: 'Manual',
    srt:  SrtConfig(host: ip, port: port),
  );

  /// Create an RTMP config from manual URL entry
  static ConnectionConfig fromRtmpUrl(String url) => ConnectionConfig(
    host: 'Manual',
    rtmp: RtmpConfig(url: url),
  );
}
