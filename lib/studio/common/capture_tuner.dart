import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Asks the phone's camera processor for its best noise reduction, sharpening and tone mapping on a camera opened
/// with getUserMedia (native CaptureTuner, 2026-10-19). It checks on its own that the camera keeps its frame rate and
/// goes back to the fast processing if not.
class CaptureTuner {
  CaptureTuner._();
  static const _channel = MethodChannel('com.samba.studio/capture');

  /// Tunes the camera behind [stream]'s video track (no-op without one / off Android).
  static Future<void> tune(MediaStream? stream, {bool high = true}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final v = stream?.getVideoTracks() ?? const [];
    if (v.isEmpty || v.first.id == null) return;
    try {
      await _channel.invokeMethod('tune', {'trackId': v.first.id, 'high': high});
    } catch (e) {
      debugPrint('[CaptureTuner] $e');
    }
  }
}
