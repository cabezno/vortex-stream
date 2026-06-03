import 'dart:convert';

// =============================================================================
// ConnectionConfig — parsed from the QR JSON produced by VortexEngine
//
// QR format (all fields optional except "app"):
// {
//   "v": 1,
//   "app": "vortexcam",
//   "host": "VortexEngine",
//   "wifi":  { "ssid": "VortexHotspot", "password": "vortex1234" },  // only when PC hotspot active
//   "whip":  { "url": "http://192.168.x.x:8080/whip/" },
//   "srt":   { "host": "192.168.x.x", "port": 9000, "latencyMs": 80 },
//   "rtmp":  { "url": "rtmp://192.168.x.x:1935/live/vortexcam" },
//   "video": { "codec": "h264", "w": 1920, "h": 1080, "fps": 60, "maxKbps": 8000 }
// }
//
// Layers:
//   wifi  = NETWORK layer — how to reach the PC's network (optional, hotspot only)
//   whip/srt/rtmp = TRANSPORT layer — how to send video (can coexist, user/auto picks one)
// =============================================================================

enum Transport { whip, srt, rtmp, omt }

/// Network layer — credentials for the PC's WiFi hotspot.
/// Present only when VortexEngine is running its own hotspot.
/// The app connects to this network BEFORE initiating the video transport.
class WifiConfig {
  final String ssid;
  final String password;
  const WifiConfig({required this.ssid, required this.password});
}

class OmtConfig {
  final int    port;
  final int    quality;   // 0=Low 1=Med 2=High
  const OmtConfig({this.port = 5960, this.quality = 2});
}

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
  final WifiConfig? wifi;   // network layer (optional, only with PC hotspot)
  final WhipConfig? whip;
  final SrtConfig?  srt;
  final RtmpConfig? rtmp;
  final OmtConfig?  omt;
  final VideoConfig video;

  const ConnectionConfig({
    required this.host,
    this.wifi,
    this.whip,
    this.srt,
    this.rtmp,
    this.omt,
    this.video = const VideoConfig(),
  });

  /// Returns the preferred transport: OMT (LAN) > SRT > WHIP > RTMP
  Transport get preferredTransport {
    if (omt  != null) return Transport.omt;
    if (srt  != null) return Transport.srt;
    if (whip != null) return Transport.whip;
    if (rtmp != null) return Transport.rtmp;
    return Transport.whip;
  }

  bool get hasWifi => wifi != null;
  bool get hasSrt  => srt  != null;
  bool get hasWhip => whip != null;
  bool get hasRtmp => rtmp != null;
  bool get hasOmt  => omt  != null;

  /// Available video transports (network layer not included).
  List<Transport> get availableTransports => [
    if (hasOmt)  Transport.omt,
    if (hasSrt)  Transport.srt,
    if (hasWhip) Transport.whip,
    if (hasRtmp) Transport.rtmp,
  ];

  static ConnectionConfig? tryParse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['app'] != 'vortexcam') return null;

      WifiConfig? wifi;
      WhipConfig? whip;
      SrtConfig?  srt;
      RtmpConfig? rtmp;
      OmtConfig?  omt;

      if (j['wifi'] is Map) {
        final ssid = (j['wifi']['ssid'] ?? '').toString();
        final pass = (j['wifi']['password'] ?? '').toString();
        if (ssid.isNotEmpty) wifi = WifiConfig(ssid: ssid, password: pass);
      }
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

      if (j['omt'] is Map) {
        final port    = (j['omt']['port']    as num?)?.toInt() ?? 5960;
        final quality = (j['omt']['quality'] as num?)?.toInt() ?? 2;
        omt = OmtConfig(port: port, quality: quality);
      }

      if (whip == null && srt == null && rtmp == null && omt == null) return null;

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
        wifi:  wifi,
        whip:  whip,
        srt:   srt,
        rtmp:  rtmp,
        omt:   omt,
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
