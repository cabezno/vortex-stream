/// Simulcast layer constants and specifications for SAMBA Móvil Studio.
class SimulcastLayers {
  SimulcastLayers._();

  /// Low-resolution preview layer (always active, lightweight for multiview).
  static const String ridLow = 'low';
  static const int lowWidth = 320;
  static const int lowHeight = 180;
  static const int lowMaxBitrate = 150000; // 150 kbps
  static const int lowMaxFramerate = 15;
  static const double lowScaleResolutionDownBy = 4.0;

  /// High-definition program layer (activated on-demand for the on-air camera).
  /// 1080p since 2026-10-04 (was 720p at WebRTC's default ~2.5 Mbps: the switcher's program looked soft). It is an
  /// IDEAL, not a minimum: a phone that can't capture/encode it gets less, and WebRTC lowers the resolution by itself
  /// if the CPU can't keep up.
  static const String ridHigh = 'high';
  static const int highWidth = 1920;
  static const int highHeight = 1080;
  static const int highMaxBitrate = 6000000; // 6 Mbps
  static const int highMinBitrate = 3500000; // 3.5 Mbps floor (see publisher.dart): at 2 Mbps VP8 still scaled 1080p to 720p/540p
  static const int highMaxFramerate = 30;
  static const double highScaleResolutionDownBy = 1.0;
}
