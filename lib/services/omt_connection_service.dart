import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// =============================================================================
// OmtConnectionService — OMT transport via OmtStreamPlugin native channel
//
// OMT (Open Media Transport) sender: phone → VortexEngine
// - VMX codec (libvmx.so ARM64, 4:2:2)
// - TCP server on phone (VortexEngine connects)
// - mDNS _omt._tcp.local discovery
// - Quality: Low (~43 Mbps) / Medium (~100 Mbps) / High (~130 Mbps) at 1080p30
// =============================================================================

enum OmtState { idle, starting, streaming, error }

class OmtConnectionService extends ChangeNotifier {
  static const _ch = MethodChannel('com.vortex.vortexcam/omt');

  OmtState _state       = OmtState.idle;
  String   _errorMsg    = '';
  bool     _connected   = false;
  int      _listenPort  = 0;
  int      _framesSent  = 0;
  double   _mbpsSent    = 0.0;

  int  _width   = 1920;
  int  _height  = 1080;
  int  _fps     = 30;
  int  _quality = 2;     // 0=Low 1=Med 2=High
  String _name  = 'VortexCam';

  OmtState get state       => _state;
  bool     get isStreaming  => _state == OmtState.streaming;
  String   get errorMsg    => _errorMsg;
  bool     get connected   => _connected;
  int      get listenPort  => _listenPort;
  int      get framesSent  => _framesSent;
  double   get mbpsSent    => _mbpsSent;

  void configure({
    int width = 1920, int height = 1080,
    int fps = 30, int quality = 2, String name = 'VortexCam',
  }) {
    _width = width; _height = height;
    _fps = fps; _quality = quality; _name = name;
  }

  Future<void> start({int port = 5960}) async {
    _state = OmtState.starting;
    _errorMsg = '';
    notifyListeners();

    try {
      final result = await _ch.invokeMethod<Map>('startOmt', {
        'width':   _width,
        'height':  _height,
        'fps':     _fps,
        'quality': _quality,
        'name':    _name,
        'port':    port,
      });
      _listenPort = (result?['port'] as int?) ?? port;
      _state = OmtState.streaming;
      notifyListeners();
      _startStatsPolling();
      debugPrint('[OmtService] streaming → :$_listenPort  ${_width}x$_height @${_fps}fps q=$_quality');
    } catch (e) {
      _state = OmtState.error;
      _errorMsg = e.toString();
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (_state == OmtState.idle) return;
    await _ch.invokeMethod('stopOmt');
    _state = OmtState.idle;
    _connected = false;
    _listenPort = 0;
    _framesSent = 0;
    _mbpsSent = 0;
    notifyListeners();
  }

  void _startStatsPolling() {
    int prevBytes = 0;
    Timer.periodic(const Duration(seconds: 2), (t) async {
      if (_state != OmtState.streaming) { t.cancel(); return; }
      try {
        final s = await _ch.invokeMethod<Map>('getStats');
        if (s != null) {
          _connected  = (s['connected'] as bool?) ?? false;
          _framesSent = (s['framesSent'] as int?)  ?? 0;
          final bytes = (s['bytesSent'] as int?) ?? 0;
          _mbpsSent   = (bytes - prevBytes) * 8.0 / 2.0 / 1e6;
          prevBytes   = bytes;
          notifyListeners();
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() { stop(); super.dispose(); }
}
