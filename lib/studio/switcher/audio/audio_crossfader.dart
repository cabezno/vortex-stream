import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Smooth equal-power / linear crossfader for switching audio between camera peers.
/// Eliminates clicks and pops when changing active speaker or camera.
class AudioCrossfader extends ChangeNotifier {
  final int durationMs;

  String? _fromPeerId;
  String? _toPeerId;
  DateTime? _crossfadeStartTime;
  Timer? _ticker;

  double _fromGain = 0.0;
  double _toGain = 1.0;
  bool _isCrossfading = false;

  void Function(String from, String to)? onCrossfadeStart;
  void Function(String to)? onCrossfadeComplete;

  AudioCrossfader({this.durationMs = 120});

  bool get isCrossfading => _isCrossfading;
  String? get activePeerId => _toPeerId;

  /// Returns the current instantaneous gain (0.0 to 1.0) for a peer.
  double getGain(String peerId) {
    if (!_isCrossfading) {
      return peerId == _toPeerId ? 1.0 : 0.0;
    }

    if (peerId == _toPeerId) {
      return _toGain;
    } else if (peerId == _fromPeerId) {
      return _fromGain;
    }
    return 0.0;
  }

  /// Trigger crossfade to a new active peer
  void crossfadeTo(String newPeerId) {
    if (newPeerId == _toPeerId && !_isCrossfading) return;

    _ticker?.cancel();
    _fromPeerId = _toPeerId;
    _toPeerId = newPeerId;

    if (_fromPeerId == null) {
      // First camera: snap to 1.0 immediately
      _fromGain = 0.0;
      _toGain = 1.0;
      _isCrossfading = false;
      notifyListeners();
      return;
    }

    _isCrossfading = true;
    _crossfadeStartTime = DateTime.now();
    onCrossfadeStart?.call(_fromPeerId!, _toPeerId!);

    // Run high-resolution tick (~10ms)
    _ticker = Timer.periodic(const Duration(milliseconds: 10), (_) => _tick());
    _tick();
  }

  void _tick() {
    if (_crossfadeStartTime == null) return;

    final elapsedMs = DateTime.now().difference(_crossfadeStartTime!).inMilliseconds;
    final progress = (elapsedMs / durationMs).clamp(0.0, 1.0);

    // Equal-power crossfade curve: cos/sin to maintain constant acoustic power:
    // gain_from = cos(progress * pi / 2)
    // gain_to   = sin(progress * pi / 2)
    final angle = progress * (math.pi / 2.0);
    _fromGain = math.cos(angle);
    _toGain = math.sin(angle);

    notifyListeners();

    if (progress >= 1.0) {
      _ticker?.cancel();
      _ticker = null;
      _isCrossfading = false;
      _fromGain = 0.0;
      _toGain = 1.0;
      final completedPeer = _toPeerId!;
      _fromPeerId = null;
      notifyListeners();
      onCrossfadeComplete?.call(completedPeer);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}
