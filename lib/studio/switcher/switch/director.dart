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

    // Chain, don't replace: the subscriber registered onPeerLeft first (closes the camera's connection) — assigning
    // over it left a departed camera's WebRTC session open (found 2026-10-06).
    final prevJoined = roomHost.onPeerJoined, prevLeft = roomHost.onPeerLeft;
    roomHost.onPeerJoined = (p) { prevJoined?.call(p); _syncPeers(); };
    roomHost.onPeerLeft = (id) { prevLeft?.call(id); _syncPeers(); };

    _startEngineLoop();
  }

  AudioSwitcherEngine get engine => _engine;
  AudioCrossfader get crossfader => _crossfader;
  SwitcherConfig get config => _engine.config;
  bool get isAutoSwitch => _engine.config.autoSwitch;
  String? get activePeerId => roomHost.activePeerId;
  List<String> get switchHistory => List.unmodifiable(_switchHistory);

  /// Every microphone the engine listens to: each camera's own and the «Solo micrófono» phones.
  void _syncPeers() {
    final micIds = roomHost.mics.map((m) => m.id).toList();
    _engine.setPeers([...roomHost.cameras.map((c) => c.id), ...micIds]);
    _engine.micOnly..clear()..addAll(micIds);
    notifyListeners();
  }

  /// Mic → camera table (null = default: a camera's mic cuts to itself, a mic-only phone does not cut; '' = never).
  void setMicTarget(String micId, String? cameraId) {
    if (cameraId == null) {
      _engine.config.micToCamera.remove(micId);
    } else {
      _engine.config.micToCamera[micId] = cameraId;
    }
    notifyListeners();
  }

  /// The camera [micId] cuts to now (null = it does not cut).
  String? micTarget(String micId) => _engine.targetOf(micId);

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
    _goOnAir(event.targetPeerId);
  }

  /// Puts [peerId] on air. The camera that was on air goes to PREVIEW: it stays at high quality, so cutting back is
  /// instant — the usual back-and-forth of two people talking never waits for a camera to go up (PGM/PVW, 2026-10-06).
  void _goOnAir(String peerId) {
    final previous = roomHost.activePeerId;
    _crossfader.crossfadeTo(peerId);
    subscriber?.updateActiveAudioTrack(peerId);
    roomHost.setActiveCamera(peerId);
    if (previous != null && previous != peerId && roomHost.room.peers.containsKey(previous)) {
      roomHost.setPreviewCamera(previous);
    }
    notifyListeners();
  }

  String? get previewPeerId => roomHost.previewPeerId;

  /// Prepare a camera in PREVIEW (green): it goes up to high quality while the program keeps showing the on-air one.
  void setPreview(String peerId) {
    if (peerId == roomHost.activePeerId) return;
    roomHost.setPreviewCamera(peerId);
    _recordSwitchLog('Preparada en vista previa: ${_nameOf(peerId)}');
    notifyListeners();
  }

  /// CUT: the preview camera goes on air (and the on-air one to preview).
  void cutToPreview() {
    final pvw = roomHost.previewPeerId;
    if (pvw != null) manualCut(pvw);
  }

  String _nameOf(String peerId) => roomHost.room.peers[peerId]?.name ?? peerId;

  void _recordSwitchLog(String log) {
    final timeStr = DateTime.now().toIso8601String().substring(11, 19);
    _switchHistory.insert(0, '[$timeStr] $log');
    if (_switchHistory.length > 50) {
      _switchHistory.removeLast();
    }
  }

  /// Manually cut to a specific camera with audio crossfade
  void manualCut(String peerId) {
    final fromPreview = peerId == roomHost.previewPeerId;
    _recordSwitchLog('Corte ${fromPreview ? 'desde vista previa' : 'directo'} a ${_nameOf(peerId)}');
    _engine.setActivePeer(peerId, resetHoldTimer: true);
    _goOnAir(peerId);
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
    // '' clears the overlap / silence shot (back to: loudest speaker / stay).
    if (overlapPeerId != null) _engine.config.overlapPeerId = overlapPeerId.isEmpty ? null : overlapPeerId;
    if (silencePeerId != null) _engine.config.silencePeerId = silencePeerId.isEmpty ? null : silencePeerId;
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
