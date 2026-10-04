import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Reads microphone audio energy from WebRTC stats,
/// calculates RMS in dBFS (-100.0 to 0.0), and reports it periodically
/// to the control client for distributed edge VAD.
class VadReporter {
  final Future<RTCPeerConnection?> Function() getPeerConnection;
  final void Function(double dbfs) onAudioLevel;

  Timer? _pollTimer;
  double _currentDbfs = -100.0;
  double _smoothedDbfs = -100.0;

  VadReporter({
    required this.getPeerConnection,
    required this.onAudioLevel,
  });

  double get currentDbfs => _currentDbfs;
  double get smoothedDbfs => _smoothedDbfs;

  /// Start polling audio stats at ~20Hz (every 50ms)
  void start() {
    stop();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => _pollAudioStats());
  }

  Future<void> _pollAudioStats() async {
    final pc = await getPeerConnection();
    if (pc == null) return;

    try {
      final stats = await pc.getStats();
      for (final report in stats) {
        // Look for outbound audio track stats
        if (report.type == 'outbound-rtp' && report.values['mediaType'] == 'audio' ||
            report.type == 'media-source' && report.values['kind'] == 'audio') {
          final levelVal = report.values['audioLevel'];
          if (levelVal != null) {
            final double linearLevel = (levelVal as num).toDouble();
            if (linearLevel > 0.00001) {
              // Convert linear [0..1] to dBFS
              _currentDbfs = 20.0 * (math.log(linearLevel) / math.ln10);
              _currentDbfs = _currentDbfs.clamp(-100.0, 0.0);
            } else {
              _currentDbfs = -100.0;
            }

            // Exponential smoothing (alpha = 0.35)
            _smoothedDbfs = (_smoothedDbfs * 0.65) + (_currentDbfs * 0.35);
            onAudioLevel(_smoothedDbfs);
            return;
          }
        }
      }
    } catch (_) {
      // Ignore transient stats errors during renegotiation
    }
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void dispose() {
    stop();
  }
}
