import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum CameraFacing { back, front }

// =============================================================================
// CameraService — manages device camera and MediaStream for WebRTC
//
// Resolution priority (highest wins):
//   1. Engine-requested via requestResolution() from data channel
//   2. Manual user selection via setResolution()
//   3. Default: maximum camera resolution (ideal 4K, no minimum)
// =============================================================================

enum CameraResolution { r720p, r1080p, r4k }

class CameraService extends ChangeNotifier {
  MediaStream?     _stream;
  CameraFacing     _facing      = CameraFacing.back;
  CameraResolution _resolution  = CameraResolution.r1080p;
  bool             _torchOn     = false;
  bool             _initialized = false;

  // Resolution requested by VortexEngine over the data channel.
  // null = no engine override, use _resolution.
  int? _engineWidth;
  int? _engineHeight;

  MediaStream?     get stream        => _stream;
  bool             get isInitialized => _initialized;
  CameraFacing     get facing        => _facing;
  CameraResolution get resolution    => _resolution;
  bool             get torchOn       => _torchOn;

  // Label for the UI — shows engine-requested resolution if active,
  // otherwise the local enum selection.
  String get resolutionLabel {
    if (_engineWidth != null && _engineHeight != null) {
      // Format as "1080p", "720p", "4K" when it matches a standard, else "WxH"
      if (_engineWidth == 3840 && _engineHeight == 2160) return '4K';
      if (_engineWidth == 1920 && _engineHeight == 1080) return '1080p';
      if (_engineWidth == 1280 && _engineHeight == 720)  return '720p';
      return '${_engineWidth}x${_engineHeight}';
    }
    return _localResLabel;
  }

  String get _localResLabel => switch (_resolution) {
    CameraResolution.r720p  => '720p',
    CameraResolution.r1080p => '1080p',
    CameraResolution.r4k    => '4K',
  };

  // ---- Init camera + create MediaStream ----
  Future<void> initialize() async {
    await _buildStream();
    _initialized = true;
    notifyListeners();
  }

  Future<void> _buildStream() async {
    _stream?.getTracks().forEach((t) => t.stop());

    // If the engine has requested a specific resolution, apply it with
    // min+ideal to lock it exactly. Otherwise use high ideal values
    // (no min) so the camera HAL picks the best resolution it supports.
    final Map<String, dynamic> videoConstraints;
    if (_engineWidth != null && _engineHeight != null) {
      videoConstraints = {
        'facingMode': _facing == CameraFacing.back ? 'environment' : 'user',
        'width':  {'min': _engineWidth,  'ideal': _engineWidth},
        'height': {'min': _engineHeight, 'ideal': _engineHeight},
        'frameRate': {'ideal': 60, 'min': 30},
      };
    } else {
      // No engine constraint and no manual selection: let the camera HAL pick
      // the highest resolution it supports (16:9, up to 4K).
      // Using 'ideal' without 'min' allows the HAL to go lower if 4K isn't
      // available — the engine will request a specific resolution anyway once
      // the data channel opens.
      videoConstraints = {
        'facingMode': _facing == CameraFacing.back ? 'environment' : 'user',
        'width':  {'ideal': 3840},
        'height': {'ideal': 2160},
        'frameRate': {'ideal': 60, 'min': 30},
        'aspectRatio': {'ideal': 1.7778},  // force 16:9 (not 4:3 native sensor)
      };
    }

    _stream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl':  true,
      },
      'video': videoConstraints,
    });
    debugPrint('[CameraService] Stream ready: $resolutionLabel'
        ' (engine=${_engineWidth != null})');
  }

  // ---- Called by ConnectionService when VortexEngine requests a resolution ----
  // Rebuilds the MediaStream at the new resolution and notifies listeners.
  Future<void> applyResolutionFromEngine(int width, int height) async {
    if (_engineWidth == width && _engineHeight == height) return;
    _engineWidth  = width;
    _engineHeight = height;
    await _buildStream();
    notifyListeners();
  }

  // ---- Manual user resolution selection (overrides engine value) ----
  Future<void> setResolution(CameraResolution res) async {
    _resolution   = res;
    _engineWidth  = null;   // manual override clears engine constraint
    _engineHeight = null;
    await _buildStream();
    notifyListeners();
  }

  // ---- Flip camera ----
  Future<void> flipCamera() async {
    _facing = _facing == CameraFacing.back ? CameraFacing.front : CameraFacing.back;
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

  int _resolutionWidth() => switch (_resolution) {
    CameraResolution.r720p  => 1280,
    CameraResolution.r1080p => 1920,
    CameraResolution.r4k    => 3840,
  };

  int _resolutionHeight() => switch (_resolution) {
    CameraResolution.r720p  => 720,
    CameraResolution.r1080p => 1080,
    CameraResolution.r4k    => 2160,
  };

  @override
  void dispose() {
    _stream?.getTracks().forEach((t) => t.stop());
    super.dispose();
  }
}
