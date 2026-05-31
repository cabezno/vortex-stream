import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// =============================================================================
// RtmpConnectionService — RTMP transport via VortexCamPlugin native channel
//
// Uses Camera2 + MediaCodec H.264 → RTMP.
// Preview: native Camera2 texture (Texture widget, textureId from plugin).
// =============================================================================

enum RtmpState { idle, connecting, streaming, error }

class RtmpConnectionService extends ChangeNotifier {
  static const _channel = MethodChannel('com.vortex.vortexcam/native');

  RtmpState _state      = RtmpState.idle;
  String    _rtmpUrl    = '';
  String    _errorMsg   = '';
  double    _bitrateMbps = 0.0;
  int       _latencyMs  = 0;
  int?      _textureId;

  RtmpState get state        => _state;
  bool      get isStreaming   => _state == RtmpState.streaming;
  String    get rtmpUrl       => _rtmpUrl;
  String    get errorMsg      => _errorMsg;
  double    get bitrateMbps   => _bitrateMbps;
  int       get latencyMs     => _latencyMs;
  int?      get textureId     => _textureId;

  int    _width      = 1280;
  int    _height     = 720;
  int    _bitrateBps = 4000000;
  int    _keyframeMs = 2000;

  void configure({
    int width = 1280, int height = 720,
    int bitrateBps = 4000000, int keyframeMs = 2000,
  }) {
    _width = width; _height = height;
    _bitrateBps = bitrateBps; _keyframeMs = keyframeMs;
    notifyListeners();
  }

  Future<void> startCamera({bool frontCamera = false}) async {
    try {
      final result = await _channel.invokeMethod<Map>('startCamera', {
        'facing': frontCamera ? 'front' : 'back',
      });
      _textureId = result?['textureId'] as int?;
      notifyListeners();
    } catch (e) {
      _state = RtmpState.error;
      _errorMsg = 'Camera failed: $e';
      notifyListeners();
    }
  }

  Future<void> connect(String rtmpUrl) async {
    _rtmpUrl  = rtmpUrl;
    _state    = RtmpState.connecting;
    _errorMsg = '';
    notifyListeners();

    try {
      await _channel.invokeMethod('startRtmp', {
        'rtmpUrl':    rtmpUrl,
        'width':      _width,
        'height':     _height,
        'bitrateBps': _bitrateBps,
        'keyframeMs': _keyframeMs,
      });
      _state = RtmpState.streaming;
      notifyListeners();
      _startStatsPolling();
      debugPrint('[VortexCam RTMP] Streaming → $rtmpUrl');
    } catch (e) {
      _state    = RtmpState.error;
      _errorMsg = e.toString();
      notifyListeners();
    }
  }

  void _startStatsPolling() {
    Timer.periodic(const Duration(seconds: 2), (t) async {
      if (_state != RtmpState.streaming) { t.cancel(); return; }
      try {
        final s = await _channel.invokeMethod<Map>('getStats');
        if (s != null) {
          _bitrateMbps = (s['bitrateMbps'] as num?)?.toDouble() ?? 0.0;
          _latencyMs   = (s['rttMs']       as num?)?.toInt()    ?? 0;
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  Future<void> stop() async {
    if (_state == RtmpState.idle) return;
    await _channel.invokeMethod('stopRtmp');
    _state = RtmpState.idle;
    _bitrateMbps = 0; _latencyMs = 0;
    notifyListeners();
  }

  Future<void> stopCamera() async {
    await stop();
    await _channel.invokeMethod('stopCamera');
    _textureId = null;
    notifyListeners();
  }

  Future<void> flipCamera() async {
    await _channel.invokeMethod('flipCamera');
  }

  Future<void> setTorch(bool on) async {
    await _channel.invokeMethod('setTorch', {'on': on});
  }

  @override
  void dispose() { stopCamera(); super.dispose(); }
}
