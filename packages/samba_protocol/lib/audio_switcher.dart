import 'dart:math' as math;
import 'models.dart';

/// Track state tracking RMS volume and onset duration per peer.
class AudioSwitcherTrackState {
  final String peerId;
  bool enabled;
  bool active;
  double onsetAccumMs;
  double rmsDb;

  AudioSwitcherTrackState({
    required this.peerId,
    this.enabled = true,
    this.active = false,
    this.onsetAccumMs = 0.0,
    this.rmsDb = -100.0,
  });
}

/// Telemetry status of the audio switcher for inspection and UI.
class AudioSwitcherStatus {
  String? activePeerId;
  String? pendingPeerId;
  double silenceTimerSec;
  double holdTimerSec;
  int activeCount;
  bool inOverlap;
  bool inSilence;
  String? lastSwitchLog;

  AudioSwitcherStatus({
    this.activePeerId,
    this.pendingPeerId,
    this.silenceTimerSec = 0.0,
    this.holdTimerSec = 0.0,
    this.activeCount = 0,
    this.inOverlap = false,
    this.inSilence = false,
    this.lastSwitchLog,
  });
}

/// Result of a switch action triggered by the audio switcher.
class SwitchEvent {
  final String targetPeerId;
  final String reason;
  final DateTime timestamp;

  SwitchEvent({
    required this.targetPeerId,
    required this.reason,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() => 'SwitchEvent(target: $targetPeerId, reason: "$reason")';
}

/// Pure algorithmic Audio Switcher engine (1:1 port from SAMBA v1 / Rust).
///
/// Features:
/// 1. Voice activity detection with onset hold (default 80ms) to reject false transient spikes.
/// 2. Overlap handling (2+ active speakers): switch to dedicated overlap peer (e.g. wide shot) or loudest speaker.
/// 3. Silence handling: switch to silence peer after silence_delay_sec.
/// 4. Anti-chatter: enforces hold_time_sec before allowing another switch.
/// 5. Callback/Delegation pattern: accepts `onSwitch` callback for pure architectural decoupling.
class AudioSwitcherEngine {
  SwitcherConfig config;
  final Map<String, AudioSwitcherTrackState> _tracks = {};
  String? _currentActivePeerId;
  double _holdTimerSec = 100.0; // Starts ready to switch without initial lock
  double _silenceTimerSec = 0.0;
  final AudioSwitcherStatus status = AudioSwitcherStatus();

  /// Optional notification callback invoked whenever a scene/camera switch occurs.
  void Function(SwitchEvent event)? onSwitch;

  AudioSwitcherEngine({
    SwitcherConfig? config,
    this.onSwitch,
  }) : config = config ?? SwitcherConfig();

  String? get currentActivePeerId => _currentActivePeerId;
  double get holdTimerSec => _holdTimerSec;
  double get silenceTimerSec => _silenceTimerSec;
  List<AudioSwitcherTrackState> get tracks => _tracks.values.toList();

  /// Register or update known camera peers.
  void setPeers(List<String> peerIds) {
    // Preserve existing states for remaining peers
    final existingIds = Set<String>.from(_tracks.keys);
    final newIds = Set<String>.from(peerIds);

    for (final removed in existingIds.difference(newIds)) {
      _tracks.remove(removed);
    }
    for (final added in newIds.difference(existingIds)) {
      _tracks[added] = AudioSwitcherTrackState(peerId: added);
    }
  }

  /// Manually force or initialize current active peer.
  /// If [resetHoldTimer] is true (default for manual director cuts),
  /// the hold timer resets to 0.0 to prevent immediate bouncing.
  void setActivePeer(String? peerId, {bool resetHoldTimer = true}) {
    _currentActivePeerId = peerId;
    if (resetHoldTimer) {
      _holdTimerSec = 0.0;
    }
  }

  /// Feed current measured RMS (in dBFS) for a specific peer.
  /// [dtMs] is the time elapsed since last measurement (e.g. ~50ms or ~100ms).
  void feedPeerRms(String peerId, double rmsDb, double dtMs) {
    if (!config.autoSwitch) return;

    final state = _tracks[peerId];
    if (state == null) return;

    state.rmsDb = rmsDb;
    final isAbove = rmsDb > config.thresholdDbfs;
    if (isAbove && state.enabled) {
      state.onsetAccumMs = math.min(
        state.onsetAccumMs + dtMs,
        config.onsetMs + dtMs,
      );
      if (!state.active && state.onsetAccumMs >= config.onsetMs) {
        state.active = true;
      }
    } else {
      state.onsetAccumMs = 0.0;
      state.active = false;
    }
  }

  /// Feed current measured RMS (in dBFS) for multiple peers.
  void feedRms(Map<String, double> peerRms, double dtMs) {
    if (!config.autoSwitch) return;
    for (final entry in peerRms.entries) {
      feedPeerRms(entry.key, entry.value, dtMs);
    }
  }

  /// Evaluates state progression and switching logic.
  /// [dtSec] is time delta in seconds (e.g. 0.05 or 0.1s).
  /// Returns [SwitchEvent] if a switch was performed, or null otherwise.
  SwitchEvent? tick(double dtSec) {
    if (!config.autoSwitch || _tracks.isEmpty) {
      return null;
    }

    _holdTimerSec += dtSec;

    // Collect active peers
    final activeTracks = _tracks.values.where((t) => t.enabled && t.active).toList();
    final activeCount = activeTracks.length;

    if (activeCount > 0) {
      _silenceTimerSec = 0.0;
    } else {
      _silenceTimerSec += dtSec;
    }

    String? desiredPeerId;
    String switchReason = '';

    if (activeCount == 0) {
      // Silence rule
      if (config.silencePeerId != null && _silenceTimerSec >= config.silenceSec) {
        desiredPeerId = config.silencePeerId;
        switchReason = 'Silencio sostenido (${_silenceTimerSec.toStringAsFixed(1)}s)';
      }
    } else if (activeCount > 1) {
      // Overlap rule
      if (config.overlapPeerId != null) {
        desiredPeerId = config.overlapPeerId;
        switchReason = 'Solapamiento: $activeCount oradores hablando a la vez';
      } else {
        // Tie-breaker by loudest RMS dBFS
        AudioSwitcherTrackState loudest = activeTracks.first;
        for (int i = 1; i < activeTracks.length; i++) {
          if (activeTracks[i].rmsDb > loudest.rmsDb) {
            loudest = activeTracks[i];
          }
        }
        desiredPeerId = loudest.peerId;
        switchReason = 'Desempate por volumen: ${loudest.peerId} más fuerte (${loudest.rmsDb.toStringAsFixed(1)} dBFS)';
      }
    } else {
      // Exactly 1 speaker active
      final single = activeTracks.first;
      desiredPeerId = single.peerId;
      switchReason = 'Orador activo en ${single.peerId} (${single.rmsDb.toStringAsFixed(1)} dBFS)';
    }

    // Telemetry updates
    status.activeCount = activeCount;
    status.silenceTimerSec = _silenceTimerSec;
    status.holdTimerSec = _holdTimerSec;
    status.inOverlap = activeCount > 1;
    status.inSilence = activeCount == 0 && _silenceTimerSec >= config.silenceSec;
    status.pendingPeerId = desiredPeerId;

    // Anti-chatter enforcement
    if (desiredPeerId != null) {
      if (desiredPeerId == _currentActivePeerId) {
        return null;
      }
      if (_holdTimerSec < config.holdSec) {
        return null;
      }

      // Valid switch executed
      _currentActivePeerId = desiredPeerId;
      _holdTimerSec = 0.0;
      status.activePeerId = desiredPeerId;
      status.lastSwitchLog = switchReason;

      final event = SwitchEvent(
        targetPeerId: desiredPeerId,
        reason: switchReason,
      );

      // Invoke delegation callback
      onSwitch?.call(event);

      return event;
    }

    return null;
  }
}
