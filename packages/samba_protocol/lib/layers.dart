/// Simulcast layer constants and specifications for SAMBA Móvil Studio.
class SimulcastLayers {
  SimulcastLayers._();

  /// Low layer: cameras that are neither on air, in preview nor the second camera of a split/PiP (2026-10-06, PGM/PVW).
  /// Each camera sends ONE stream and the switcher changes its quality (set_layer): only the on-air and the next
  /// cameras cost full decode/Wi-Fi. 360p, not 180p: a direct cut (auto-switch) shows this layer for the half second
  /// the camera takes to go up, so it must look acceptable on air.
  static const String ridLow = 'low';
  static const int lowHeight = 360;
  static const int lowMaxBitrate = 600000; // 600 kbps
  static const int lowMaxFramerate = 15;

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
