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
  static const String ridHigh = 'high';
  static const int highWidth = 1280;
  static const int highHeight = 720;
  static const int highMaxBitrate = 3000000; // 3 Mbps
  static const int highMaxFramerate = 30;
  static const double highScaleResolutionDownBy = 1.0;
}
