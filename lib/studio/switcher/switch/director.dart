import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:samba_protocol/samba_protocol.dart';
import '../audio/audio_crossfader.dart';
import '../room/room_host.dart';
import '../transport/subscriber.dart';

/// Director controller that coordinates manual and automatic camera switching.
/// Integrates the pure algorithmic AudioSwitcherEngine, the AudioCrossfader,
/// the RoomHost, and audio track routing.
class Director extends ChangeNotifier {
  final RoomHost roomHost;
  final WebRtcSubscriber? subscriber;
  late final AudioSwitcherEngine _engine;
  late final AudioCrossfader _crossfader;
  Timer? _engineTimer;
  final List<String> _switchHistory = [];

  Director({required this.roomHost, this.subscriber}) {
    _crossfader = AudioCrossfader(
      durationMs: roomHost.room.config.crossfadeMs,
    );

    _engine = AudioSwitcherEngine(
      config: roomHost.room.config,
      onSwitch: _handleEngineSwitch,
    );

    // Bind room host audio events into the engine
    roomHost.onAudioLevel = (peerId, dbfs) {
      if (_engine.config.autoSwitch) {
        _engine.feedPeerRms(peerId, dbfs, 50.0);
      }
    };

    roomHost.onPeerJoined = (_) => _syncPeers();
    roomHost.onPeerLeft = (_) => _syncPeers();

    _startEngineLoop();
  }

  AudioSwitcherEngine get engine => _engine;
  AudioCrossfader get crossfader => _crossfader;
  SwitcherConfig get config => _engine.config;
  bool get isAutoSwitch => _engine.config.autoSwitch;
  String? get activePeerId => roomHost.activePeerId;
  List<String> get switchHistory => List.unmodifiable(_switchHistory);

  void _syncPeers() {
    final cameraIds = roomHost.cameras.map((c) => c.id).toList();
    _engine.setPeers(cameraIds);
  }

  void _startEngineLoop() {
    _engineTimer?.cancel();
    // 20Hz evaluation loop (50ms interval)
    _engineTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_engine.config.autoSwitch) {
        _engine.tick(0.05);
      }
    });
  }

  void _handleEngineSwitch(SwitchEvent event) {
    _recordSwitchLog(event.reason);
    _crossfader.crossfadeTo(event.targetPeerId);
    subscriber?.updateActiveAudioTrack(event.targetPeerId);
    roomHost.setActiveCamera(event.targetPeerId);
    notifyListeners();
  }

  void _recordSwitchLog(String log) {
    final timeStr = DateTime.now().toIso8601String().substring(11, 19);
    _switchHistory.insert(0, '[$timeStr] $log');
    if (_switchHistory.length > 50) {
      _switchHistory.removeLast();
    }
  }

  /// Manually cut to a specific camera with audio crossfade
  void manualCut(String peerId) {
    _recordSwitchLog('Corte manual a $peerId');
    _engine.setActivePeer(peerId, resetHoldTimer: true);
    _crossfader.crossfadeTo(peerId);
    subscriber?.updateActiveAudioTrack(peerId);
    roomHost.setActiveCamera(peerId);
    notifyListeners();
  }

  /// Toggle automatic audio switching
  void toggleAutoSwitch(bool enabled) {
    _engine.config.autoSwitch = enabled;
    roomHost.room.config.autoSwitch = enabled;
    _recordSwitchLog(enabled ? 'Auto-switch ACTIVADO' : 'Auto-switch DESACTIVADO');
    notifyListeners();
  }

  /// Update Audio Switcher tuning parameters
  void updateConfig({
    double? thresholdDbfs,
    double? onsetMs,
    double? holdSec,
    double? silenceSec,
    int? crossfadeMs,
    String? overlapPeerId,
    String? silencePeerId,
  }) {
    if (thresholdDbfs != null) _engine.config.thresholdDbfs = thresholdDbfs;
    if (onsetMs != null) _engine.config.onsetMs = onsetMs;
    if (holdSec != null) _engine.config.holdSec = holdSec;
    if (silenceSec != null) _engine.config.silenceSec = silenceSec;
    if (overlapPeerId != null) _engine.config.overlapPeerId = overlapPeerId;
    if (silencePeerId != null) _engine.config.silencePeerId = silencePeerId;
    notifyListeners();
  }

  @override
  void dispose() {
    _engineTimer?.cancel();
    _engineTimer = null;
    _crossfader.dispose();
    super.dispose();
  }
}
