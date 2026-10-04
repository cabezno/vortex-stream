import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../encode/program_encoder.dart';

enum RtmpState { idle, connecting, streaming, error }

/// RTMP Multiplatform Output streamer with Adaptive Bitrate (ABR) for 5G uplinks.
class RtmpOut extends ChangeNotifier {
  final ProgramEncoder encoder;

  RtmpState _state = RtmpState.idle;
  // Por defecto apunta a SAMBA de escritorio (ingest RTMP propio, puerto 1935,
  // handshake simple compatible). Reemplazar la IP por la del PC con SAMBA en la LAN.
  String _rtmpUrl = 'rtmp://192.168.1.100:1935/live';
  String _streamKey = 'samba';
  bool _abrEnabled = true;
  DateTime? _streamStartTime;
  Timer? _metricsTimer;

  int _bytesSent = 0;
  int _currentBitrateKbps = 4500;
  String _errorMessage = '';

  RtmpOut({required this.encoder});

  RtmpState get state => _state;
  bool get isStreaming => _state == RtmpState.streaming;
  String get rtmpUrl => _rtmpUrl;
  String get streamKey => _streamKey;
  bool get abrEnabled => _abrEnabled;
  int get currentBitrateKbps => _currentBitrateKbps;
  int get bytesSent => _bytesSent;
  String get errorMessage => _errorMessage;

  Duration get streamingDuration => _streamStartTime != null
      ? DateTime.now().difference(_streamStartTime!)
      : Duration.zero;

  void configure({
    required String url,
    required String streamKey,
    bool? abrEnabled,
  }) {
    _rtmpUrl = url;
    _streamKey = streamKey;
    if (abrEnabled != null) _abrEnabled = abrEnabled;
    notifyListeners();
  }

  static const MethodChannel _channel = MethodChannel('com.samba.studio/program_encoder');

  int _droppedPackets = 0;
  bool _linkUp = true;
  int _reconnects = 0;
  bool _hasAudio = false;
  String _linkError = '';

  int get droppedPackets => _droppedPackets;
  /// Live but the link fell: the native side is reconnecting by itself.
  bool get reconnecting => isStreaming && !_linkUp;
  int get reconnects => _reconnects;
  bool get hasAudio => _hasAudio;
  String get linkError => _linkError;

  /// Start real RTMP streaming via native FLV/TCP client
  Future<void> startStream() async {
    if (_state == RtmpState.streaming) return;

    _state = RtmpState.connecting;
    _errorMessage = '';
    notifyListeners();

    try {
      // Ensure hardware encoder is running
      if (!encoder.isEncoding) {
        await encoder.start(bitrateKbps: _currentBitrateKbps);
      }

      // Connect native RTMP client
      if (!kIsWeb) {
        try {
          await _channel.invokeMethod('startRtmp', {
            'url': _rtmpUrl,
            'streamKey': _streamKey,
          });
        } on PlatformException catch (e) {
          // The server's own reason (refused key, TLS, unreachable…), shown to the user.
          throw Exception(e.message ?? e.code);
        } on MissingPluginException {
          debugPrint('[RtmpOut] Platform channel mock/fallback active');
        }
      }

      _state = RtmpState.streaming;
      _streamStartTime = DateTime.now();
      _startMetricsLoop();
      notifyListeners();
    } catch (e) {
      _state = RtmpState.error;
      _errorMessage = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  void _startMetricsLoop() {
    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!isStreaming) return;

      // Query real network stats from native RTMP client
      if (!kIsWeb) {
        try {
          final stats = await _channel.invokeMapMethod<String, dynamic>('getRtmpStats');
          if (stats != null) {
            _bytesSent = (stats['bytesSent'] as num?)?.toInt() ?? _bytesSent;
            _droppedPackets = (stats['droppedPackets'] as num?)?.toInt() ?? _droppedPackets;
            _linkUp = stats['connected'] as bool? ?? _linkUp;
            _reconnects = (stats['reconnects'] as num?)?.toInt() ?? _reconnects;
            _hasAudio = stats['hasAudio'] as bool? ?? _hasAudio;
            _linkError = stats['lastError'] as String? ?? '';
          }
        } catch (_) {}
      }

      // Real ABR adjustment based on network packet drops
      if (_abrEnabled) {
        _evaluateAbr();
      }

      notifyListeners();
    });
  }

  /// Adaptive Bitrate (ABR) algorithm: adjusts video bitrate based on dropped frames/packets
  void _evaluateAbr() {
    final dropped = _droppedPackets > 0 ? _droppedPackets : encoder.droppedFrames;
    if (dropped > 5 && _currentBitrateKbps > 1500) {
      // Throttle down on congestion
      _currentBitrateKbps = (_currentBitrateKbps - 500).clamp(1200, 4500);
      encoder.updateBitrate(_currentBitrateKbps);
      debugPrint('[ABR] Real network congestion detected (dropped=$dropped), throttling bitrate to $_currentBitrateKbps kbps');
    } else if (dropped == 0 && _currentBitrateKbps < 4500) {
      // Step up when network stabilizes
      _currentBitrateKbps = (_currentBitrateKbps + 200).clamp(1200, 4500);
      encoder.updateBitrate(_currentBitrateKbps);
    }
  }

  /// Stop RTMP streaming
  Future<void> stopStream() async {
    _metricsTimer?.cancel();
    _metricsTimer = null;

    try {
      if (!kIsWeb) {
        await _channel.invokeMethod('stopRtmp');
      }
    } catch (_) {}

    _state = RtmpState.idle;
    _streamStartTime = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stopStream();
    super.dispose();
  }
}
