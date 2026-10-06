import 'package:flutter/foundation.dart';
import '../encode/program_encoder.dart';
import '../room/room_host.dart';
import '../transport/subscriber.dart';

/// Lines up every source of the PROGRAM to the slowest one (plan §5, 2026-10-06).
///
/// The switcher's own camera and microphone arrive at once; Wi-Fi cameras 100–300 ms later (encoding, network,
/// buffer — plus a Bluetooth headset's delay). Cutting between them made time jump, a split showed two moments, and
/// the switcher's mic did not match the lips of a remote camera. The program now holds the faster sources so all
/// sit at the latency of the slowest (capped at [maxMs]: past that, the camera is flagged instead of delaying the
/// whole program). Only the program; the switcher's monitors stay live.
///
/// Latency of a camera: the BEEP measurement when taken (end to end, measure()), else WebRTC's estimate (lower: it
/// does not see capture). The switcher's own camera: [localAdjustMs], a manual fine-tune (it cannot hear itself).
class SourceSync extends ChangeNotifier {
  final RoomHost roomHost;
  final WebRtcSubscriber subscriber;
  final ProgramEncoder encoder;
  final String localPeerId;

  SourceSync({required this.roomHost, required this.subscriber, required this.encoder, required this.localPeerId}) {
    subscriber.addListener(notifyListeners);
  }

  static const int maxMs = 500;

  bool _align = true;
  bool get align => _align;
  set align(bool v) { _align = v; notifyListeners(); }

  int _localAdjustMs = 0;
  int get localAdjustMs => _localAdjustMs;
  set localAdjustMs(int v) { _localAdjustMs = v.clamp(0, maxMs); notifyListeners(); }

  final Map<String, int> measured = {};
  bool _measuring = false;
  bool get measuring => _measuring;
  String _lastResult = '';
  String get lastResult => _lastResult;

  /// Latency of [peerId] and whether it was measured (true) or estimated (false); null if unknown.
  ({int ms, bool measured})? latencyOf(String peerId) {
    if (peerId == localPeerId) return (ms: _localAdjustMs, measured: true);
    final m = measured[peerId];
    if (m != null) return (ms: m, measured: true);
    final e = subscriber.latencyEstMs[peerId];
    return e == null ? null : (ms: e, measured: false);
  }

  /// The latency everything is aligned to: the slowest connected camera, capped.
  int get targetMs {
    var t = 0;
    for (final c in roomHost.cameras) {
      final l = latencyOf(c.id)?.ms ?? 0;
      if (l <= maxMs && l > t) t = l;
    }
    return t;
  }

  /// A camera slower than the cap: shown so the user can move it closer / to 5 GHz.
  bool tooSlow(String peerId) => (latencyOf(peerId)?.ms ?? 0) > maxMs;

  /// How much the program holds [peerId] (0 when alignment is off or unknown).
  int delayFor(String? peerId) {
    if (!_align || peerId == null) return 0;
    final l = latencyOf(peerId)?.ms;
    if (l == null) return 0;
    return (targetMs - l).clamp(0, maxMs);
  }

  /// The switcher's own microphone arrives at once: held to the target.
  int get micDelayMs => _align ? targetMs : 0;

  /// Beeps on this phone's loudspeaker, timed in each camera's audio. The cameras must be within a few meters.
  Future<void> measure() async {
    if (_measuring) return;
    final tracks = <String, String>{};
    for (final c in roomHost.cameras) {
      if (c.id == localPeerId) continue;
      final a = subscriber.remoteStreams[c.id]?.getAudioTracks() ?? const [];
      if (a.isNotEmpty && a.first.id != null) tracks[c.id] = a.first.id!;
    }
    if (tracks.isEmpty) { _lastResult = 'No hay cámaras con audio para medir.'; notifyListeners(); return; }
    _measuring = true; _lastResult = ''; notifyListeners();
    final r = await encoder.measureLatency(tracks);
    _measuring = false;
    final missed = <String>[];
    for (final id in tracks.keys) {
      final v = r[id];
      final name = roomHost.room.peers[id]?.name ?? id;
      if (v == null) { missed.add(name); } else { measured[id] = v; }
    }
    _lastResult = missed.isEmpty
        ? 'Medido: ${tracks.keys.map((id) => '${roomHost.room.peers[id]?.name ?? id} ${measured[id]} ms').join(' · ')}'
        : 'No se escucharon los pitidos en: ${missed.join(', ')} (acercá esas cámaras o subí el volumen del switcher).';
    debugPrint('[SourceSync] $r → $_lastResult');
    notifyListeners();
  }

  void forget(String peerId) { measured.remove(peerId); notifyListeners(); }

  @override
  void dispose() {
    subscriber.removeListener(notifyListeners);
    super.dispose();
  }
}
