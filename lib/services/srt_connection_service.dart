import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// =============================================================================
// SrtConnectionService — SRT transport with H.265 HW encoding
//
// Uses a native Android MethodChannel that wraps:
//   Camera2 → MediaCodec H.265 HW encoder → MPEG-TS → libsrt
//
// Replaces WebRTC/WHIP for LAN use. Advantages vs WebRTC:
//   - H.265 HW encode: 6-8 Mbps at 1080p vs H.264 8-12 Mbps
//   - No GCC quality scaler: resolution stays at 1080p always
//   - No ICE/DTLS overhead: ~30ms lower latency
//   - Larix Broadcaster compatible (use during development/testing)
//
// Discovery: uses Android NsdManager to find "_srt._udp.local" on LAN.
// Engine (VortexEngine) announces this service when hotspot is active.
// =============================================================================

enum SrtState { idle, discovering, connecting, streaming, error }

class SrtConnectionService extends ChangeNotifier {
  static const _channel = MethodChannel('com.vortex.vortexcam/native');

  SrtState _state       = SrtState.idle;
  String   _engineIp    = '';
  int      _enginePort  = 9000;
  String   _errorMsg    = '';
  double   _bitrateMbps = 0.0;
  int      _latencyMs   = 0;
  bool     _isOnAir     = false;

  // Config
  int    _width            = 1280;
  int    _height           = 720;
  int    _targetBitrateBps = 6000000;  // 6 Mbps default (H.265 efficient)
  int    _keyframeIntervalS = 2;
  int    _srtLatencyMs     = 80;       // LAN-optimized buffer

  SrtState get state          => _state;
  bool     get isStreaming     => _state == SrtState.streaming;
  String   get engineIp        => _engineIp;
  int      get enginePort      => _enginePort;
  String   get errorMsg        => _errorMsg;
  double   get bitrateMbps     => _bitrateMbps;
  int      get latencyMs       => _latencyMs;
  bool     get isOnAir         => _isOnAir;
  int      get width           => _width;
  int      get height          => _height;

  // Configure video parameters before connecting
  void configure({
    int width = 1280, int height = 720,
    int targetBitrateBps = 6000000,
    int keyframeIntervalS = 2,
    int srtLatencyMs = 80,
  }) {
    _width = width; _height = height;
    _targetBitrateBps = targetBitrateBps;
    _keyframeIntervalS = keyframeIntervalS;
    _srtLatencyMs = srtLatencyMs;
    notifyListeners();
  }

  // Discover engine via mDNS (_srt._udp.local) and start streaming.
  // Falls back to manual IP if discovery times out.
  Future<void> discoverAndConnect({String? fallbackIp, int fallbackPort = 9000}) async {
    _state = SrtState.discovering;
    _errorMsg = '';
    notifyListeners();

    try {
      // Ask native side to browse _srt._udp.local for 5 seconds
      final discovered = await _channel.invokeMethod<Map>('discoverSrt', {
        'timeoutMs': 5000,
      });

      if (discovered != null && discovered['ip'] != null) {
        _engineIp   = discovered['ip'] as String;
        _enginePort = (discovered['port'] as int?) ?? 9000;
        debugPrint('[VortexCam SRT] Discovered engine: $_engineIp:$_enginePort');
      } else if (fallbackIp != null) {
        _engineIp   = fallbackIp;
        _enginePort = fallbackPort;
        debugPrint('[VortexCam SRT] Discovery timeout — using fallback $_engineIp:$_enginePort');
      } else {
        throw Exception('mDNS discovery failed and no fallback IP provided');
      }

      await _startStreaming();
    } catch (e) {
      _state    = SrtState.error;
      _errorMsg = e.toString();
      notifyListeners();
    }
  }

  // Connect to a specific engine IP:port directly (skip mDNS).
  Future<void> connectTo(String ip, {int port = 9000}) async {
    _engineIp   = ip;
    _enginePort = port;
    _errorMsg   = '';
    notifyListeners();
    try {
      await _startStreaming();
    } catch (e) {
      _state    = SrtState.error;
      _errorMsg = e.toString();
      notifyListeners();
    }
  }

  Future<void> _startStreaming() async {
    _state = SrtState.connecting;
    notifyListeners();

    await _channel.invokeMethod('startSrt', {
      'engineIp':        _engineIp,
      'enginePort':      _enginePort,
      'width':           _width,
      'height':          _height,
      'bitrateBps':      _targetBitrateBps,
      'keyframeMs':      _keyframeIntervalS * 1000,
      'srtLatencyMs':    _srtLatencyMs,
      // H.265 low-latency encoder params
      'codec':           'hevc',   // MediaCodec HEVC (H.265)
      'lowLatency':      true,     // KEY_LOW_LATENCY = 1
      'bitrateMode':     'cbr',    // BITRATE_MODE_CBR
      'priority':        0,        // KEY_PRIORITY = 0 (realtime)
      'operatingRate':   120,      // KEY_OPERATING_RATE hint
    });

    _state = SrtState.streaming;
    notifyListeners();
    debugPrint('[VortexCam SRT] Streaming started → $_engineIp:$_enginePort '
               '${_width}x$_height @${_targetBitrateBps ~/ 1000}kbps H.265');

    // Start polling stats from native side
    _startStatsPolling();
  }

  void _startStatsPolling() {
    Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_state != SrtState.streaming) { timer.cancel(); return; }
      try {
        final stats = await _channel.invokeMethod<Map>('getStats');
        if (stats != null) {
          _bitrateMbps = (stats['bitrateMbps'] as num?)?.toDouble() ?? 0.0;
          _latencyMs   = (stats['rttMs']       as num?)?.toInt()    ?? 0;
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  Future<void> stop() async {
    if (_state == SrtState.idle) return;
    await _channel.invokeMethod('stopSrt');
    _state    = SrtState.idle;
    _bitrateMbps = 0;
    _latencyMs   = 0;
    notifyListeners();
    debugPrint('[VortexCam SRT] Streaming stopped');
  }

  void setOnAir(bool active) {
    _isOnAir = active;
    notifyListeners();
  }

  @override
  void dispose() { stop(); super.dispose(); }
}
