import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// =============================================================================
// CameraService — manages device camera and MediaStream for WebRTC
// =============================================================================

enum CameraResolution { r720p, r1080p, r4k }

class CameraService extends ChangeNotifier {
  MediaStream?     _stream;
  CameraFacing     _facing     = CameraFacing.back;
  CameraResolution _resolution = CameraResolution.r720p;
  bool             _torchOn    = false;
  bool             _initialized = false;

  MediaStream?     get stream       => _stream;
  bool             get isInitialized => _initialized;
  CameraFacing     get facing       => _facing;
  CameraResolution get resolution   => _resolution;
  bool             get torchOn      => _torchOn;

  // ---- Init camera + create MediaStream ----
  Future<void> initialize() async {
    await _buildStream();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _buildStream() async {
    _stream?.getTracks().forEach((t) => t.stop());

    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': {
        'facingMode': _facing == CameraFacing.back ? 'environment' : 'user',
        // Use min+ideal so the camera HAL captures at exactly the requested resolution.
        // A bare integer is treated as "ideal" only — the Android capturer may start
        // at a lower resolution (e.g. 320x192) and the WebRTC quality scaler never
        // ramps it up without REMB feedback from the receiver.
        'width':  {'min': _resolutionWidth(),  'ideal': _resolutionWidth()},
        'height': {'min': _resolutionHeight(), 'ideal': _resolutionHeight()},
        'frameRate': {'ideal': 60, 'min': 30},
      },
    };

    _stream = await navigator.mediaDevices.getUserMedia(constraints);
    debugPrint('[CameraService] Stream ready: ${_resolutionWidth()}x${_resolutionHeight()}');
  }

  // ---- Flip camera ----
  Future<void> flipCamera() async {
    _facing = _facing == CameraFacing.back ? CameraFacing.front : CameraFacing.back;
    await _buildStream();
    notifyListeners();
  }

  // ---- Change resolution ----
  Future<void> setResolution(CameraResolution res) async {
    _resolution = res;
    await _buildStream();
    notifyListeners();
  }

  // ---- Torch ----
  Future<void> toggleTorch() async {
    _torchOn = !_torchOn;
    final videoTrack = _stream?.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await videoTrack.applyConstraints({'torch': _torchOn});
    }
    notifyListeners();
  }

  int _resolutionWidth() {
    return switch (_resolution) {
      CameraResolution.r720p  => 1280,
      CameraResolution.r1080p => 1920,
      CameraResolution.r4k    => 3840,
    };
  }

  int _resolutionHeight() {
    return switch (_resolution) {
      CameraResolution.r720p  => 720,
      CameraResolution.r1080p => 1080,
      CameraResolution.r4k    => 2160,
    };
  }

  String get resolutionLabel => switch (_resolution) {
    CameraResolution.r720p  => '720p',
    CameraResolution.r1080p => '1080p',
    CameraResolution.r4k    => '4K',
  };

  @override
  void dispose() {
    _stream?.getTracks().forEach((t) => t.stop());
    super.dispose();
  }
}
