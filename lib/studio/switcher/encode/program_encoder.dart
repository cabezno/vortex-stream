import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum EncoderCodec { h264, hevc }

class EncoderStats {
  final int width;
  final int height;
  final int targetBitrateKbps;
  final int fps;
  final int encodedFrames;
  final int droppedFrames;

  const EncoderStats({
    required this.width,
    required this.height,
    required this.targetBitrateKbps,
    required this.fps,
    this.encodedFrames = 0,
    this.droppedFrames = 0,
  });
}

/// Coordinates hardware video encoding of the Program output (1 stream ~720p).
/// Uses Android MediaCodec / iOS VideoToolbox via platform channel.
class ProgramEncoder extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('com.samba.studio/program_encoder');

  bool _isEncoding = false;
  int _width = 1920;
  int _height = 1080;
  int _bitrateKbps = 6000;
  int _fps = 30;
  EncoderCodec _codec = EncoderCodec.h264;

  int _encodedFrames = 0;
  int _droppedFrames = 0;

  /// Layout last chosen (single / splitScreen / pip). Kept even while not encoding and applied when the encoder
  /// starts: choosing SPLIT before EMITIR used to be dropped, and the transmitted program stayed "1 CAM" while the
  /// switcher's own screen showed the split (found 2026-10-04 with three phones).
  String _layoutMode = 'single';

  /// Program audio: the on-air camera's (audio follows video) and/or this phone's microphone.
  bool audioCamera = true;
  bool audioMic = false;

  /// Program height chosen by the user: 1080, or 2160 (4K) when this phone's encoder can (Emitir dialog). Applied at
  /// the next start; the native side still steps down if the video hardware refuses (it is shared with the decoders).
  int programHeight = 1080;
  bool get is4k => programHeight >= 2160;
  int get defaultKbps => is4k ? 20000 : 6000;
  /// Ceiling for the adaptive bitrate.
  int get maxKbps => is4k ? 25000 : 8000;

  bool get isEncoding => _isEncoding;
  int get width => _width;
  int get height => _height;
  int get bitrateKbps => _bitrateKbps;
  int get fps => _fps;
  EncoderCodec get codec => _codec;
  int get encodedFrames => _encodedFrames;
  int get droppedFrames => _droppedFrames;

  EncoderStats get stats => EncoderStats(
    width: _width,
    height: _height,
    targetBitrateKbps: _bitrateKbps,
    fps: _fps,
    encodedFrames: _encodedFrames,
    droppedFrames: _droppedFrames,
  );

  /// Start hardware encoding the Program stream
  Future<void> start({
    int? width,
    int? height,
    int? bitrateKbps,
    int fps = 30,
    EncoderCodec codec = EncoderCodec.h264,
    String? outputPath,
  }) async {
    _width = width ?? (is4k ? 3840 : 1920);
    _height = height ?? (is4k ? 2160 : 1080);
    _bitrateKbps = bitrateKbps ?? defaultKbps;
    _fps = fps;
    _codec = codec;

    try {
      if (!kIsWeb) {
        // The mic permission is asked only if the mic goes into the program (the switcher never needed it before).
        bool mic = false;
        if (audioMic) {
          try { mic = (await Permission.microphone.request()).isGranted; } catch (_) {}
        }
        await _channel.invokeMethod('startEncoder', {
          'audioCamera': audioCamera,
          'audioMic': mic,
          'width': _width,
          'height': _height,
          'bitrate': _bitrateKbps * 1000,
          'fps': _fps,
          'codec': _codec.name,
          if (outputPath != null) 'outputPath': outputPath,
        });
      }
    } on MissingPluginException {
      // In test/mock environment or fallback
      debugPrint('[ProgramEncoder] Platform channel mock/fallback active');
    }

    _isEncoding = true;
    if (_layoutMode != 'single') await setLayoutMode(_layoutMode);   // the layout chosen before starting
    _encodedFrames = 0;
    _droppedFrames = 0;
    notifyListeners();
  }

  /// Inform hardware GPU compositor of layout changes (single, splitScreen, pip)
  Future<void> setLayoutMode(String mode) async {
    _layoutMode = mode;
    try {
      if (!kIsWeb && _isEncoding) {
        await _channel.invokeMethod('setLayoutMode', {'mode': mode});
      }
    } catch (_) {}
  }

  /// Inform native pipeline of active WebRTC VideoTracks by their Flutter textureIds
  /// [previewTextureId]: the camera in preview, kept attached so a cut to it keeps its (already filled) delay.
  /// Delays: how much the PROGRAM holds each source to line it up with the slowest camera (SourceSync).
  Future<void> setCameraSources({int? primaryTextureId, int? secondaryTextureId, int? previewTextureId,
      String? primaryAudioTrackId, int primaryDelayMs = 0, int secondaryDelayMs = 0, int previewDelayMs = 0,
      int micDelayMs = 0}) async {
    try {
      if (!kIsWeb) {
        await _channel.invokeMethod('setCameraSources', {
          'primaryTextureId': primaryTextureId,
          'secondaryTextureId': secondaryTextureId,
          'previewTextureId': previewTextureId,
          'primaryAudioTrackId': primaryAudioTrackId,
          'primaryDelayMs': primaryDelayMs,
          'secondaryDelayMs': secondaryDelayMs,
          'previewDelayMs': previewDelayMs,
          'micDelayMs': micDelayMs,
        });
      }
    } catch (_) {}
  }

  /// «Solo micrófono» phones: received audio track id → alignment delay (ms). Always mixed into the program.
  Future<void> setMicTracks(Map<String, int> tracks) async {
    try { if (!kIsWeb) await _channel.invokeMethod('setMicTracks', {'tracks': tracks}); } catch (_) {}
  }

  /// Plays beeps on this phone's loudspeaker and times them in each camera's audio: peerId → end-to-end latency in
  /// ms (null = that camera did not hear them). [audioTrackIds]: peerId → its received audio track id.
  Future<Map<String, int?>> measureLatency(Map<String, String> audioTrackIds) async {
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('measureLatency', {'tracks': audioTrackIds});
      return {for (final e in (r ?? const {}).entries) e.key: (e.value as num?)?.toInt()};
    } catch (e) {
      debugPrint('[ProgramEncoder] measureLatency: $e');
      return {};
    }
  }

  /// Changes what the program's audio carries, live.
  Future<void> setAudioSources({required bool camera, required bool mic}) async {
    audioCamera = camera;
    bool micOk = false;
    if (mic) {
      try { micOk = (await Permission.microphone.request()).isGranted; } catch (_) {}
    }
    audioMic = micOk;
    try {
      if (!kIsWeb && _isEncoding) {
        await _channel.invokeMethod('setAudioSources', {'camera': camera, 'mic': micOk});
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Fetch real metrics from the hardware MediaCodec pipeline
  Future<Map<String, dynamic>> fetchRealStats() async {
    try {
      if (!kIsWeb && _isEncoding) {
        final res = await _channel.invokeMapMethod<String, dynamic>('getStats');
        if (res != null) {
          _encodedFrames = (res['encodedFrames'] as num?)?.toInt() ?? _encodedFrames;
          final w = (res['width'] as num?)?.toInt() ?? 0, h = (res['height'] as num?)?.toInt() ?? 0;
          if (w > 0 && h > 0) { _width = w; _height = h; }
          notifyListeners();
          return res;
        }
      }
    } catch (_) {}
    return {
      'encodedFrames': _encodedFrames,
      'droppedFrames': _droppedFrames,
      'isEncoding': _isEncoding,
    };
  }

  /// Dynamically adjust target bitrate (used by Adaptive Bitrate / ABR on 5G uplink)
  Future<void> updateBitrate(int newBitrateKbps) async {
    _bitrateKbps = newBitrateKbps.clamp(800, maxKbps);
    try {
      if (!kIsWeb && _isEncoding) {
        await _channel.invokeMethod('setBitrate', {
          'bitrate': _bitrateKbps * 1000,
        });
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Update metrics telemetry from hardware encoder
  void updateStats({required int frames, required int dropped}) {
    _encodedFrames = frames;
    _droppedFrames = dropped;
    notifyListeners();
  }

  /// Stop hardware encoder
  Future<void> stop() async {
    if (!_isEncoding) return;
    try {
      if (!kIsWeb) {
        await _channel.invokeMethod('stopEncoder');
      }
    } catch (_) {}

    _isEncoding = false;
    notifyListeners();
  }
}
