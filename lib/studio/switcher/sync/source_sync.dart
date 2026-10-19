import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
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
/// Latency of a camera: the CLAPPERBOARD measurement when taken (measure(): the flash seen in its picture, else the
/// beep heard in its audio), else WebRTC's estimate (lower: it does not see capture). The switcher's own camera: its
/// capture → arrival time from the same measurement, plus [localAdjustMs], a manual fine-tune.
class SourceSync extends ChangeNotifier {
  final RoomHost roomHost;
  final WebRtcSubscriber subscriber;
  final ProgramEncoder encoder;
  final String localPeerId;

  /// The renderer texture of a camera (its video track for the clapperboard), or null.
  final int? Function(String peerId) textureOf;

  SourceSync({required this.roomHost, required this.subscriber, required this.encoder, required this.localPeerId,
      required this.textureOf}) {
    subscriber.addListener(notifyListeners);
  }

  static const int maxMs = 500;

  bool _align = true;
  bool get align => _align;
  set align(bool v) { _align = v; notifyListeners(); }

  int _localAdjustMs = 0;
  int get localAdjustMs => _localAdjustMs;
  set localAdjustMs(int v) { _localAdjustMs = v.clamp(-200, maxMs); notifyListeners(); }

  final Map<String, int> measured = {};
  /// What the last clapperboard saw of each camera (ms; null = not detected).
  final Map<String, ({int? video, int? audio})> detail = {};
  bool _measuring = false;
  bool get measuring => _measuring;
  String _lastResult = '';
  String get lastResult => _lastResult;

  /// Latency of [peerId] and whether it was measured (true) or estimated (false); null if unknown.
  ({int ms, bool measured})? latencyOf(String peerId) {
    if (peerId == localPeerId) {
      return (ms: ((measured[peerId] ?? 0) + _localAdjustMs).clamp(0, maxMs), measured: measured.containsKey(peerId));
    }
    final m = measured[peerId];
    if (m != null) return (ms: m, measured: true);
    final e = subscriber.latencyEstMs[peerId];
    return e == null ? null : (ms: e, measured: false);
  }

  /// The latency everything is aligned to: the slowest connected camera, capped.
  int get targetMs {
    var t = 0;
    for (final c in [...roomHost.cameras, ...roomHost.mics]) {
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

  /// True while the clapperboard wants this screen white (the switcher shows a full-screen flash).
  final ValueNotifier<bool> flash = ValueNotifier(false);
  static const _flashes = 5;

  /// The CLAPPERBOARD (2026-10-19): this screen flashes white and the loudspeaker beeps [_flashes] times; each camera
  /// is timed by the flash in its picture (it must see this screen) and by the beep in its audio. The cameras must be
  /// within a few meters.
  Future<void> measure() async {
    if (_measuring) return;
    final audio = <String, String>{};
    final video = <String, int>{};
    for (final c in [...roomHost.cameras, ...roomHost.mics]) {
      final tex = textureOf(c.id);
      if (tex != null && tex >= 0) video[c.id] = tex;
      if (c.id == localPeerId) continue;
      final a = subscriber.remoteStreams[c.id]?.getAudioTracks() ?? const [];
      if (a.isNotEmpty && a.first.id != null) audio[c.id] = a.first.id!;
    }
    if (audio.isEmpty && video.isEmpty) { _lastResult = 'No hay cámaras para medir.'; notifyListeners(); return; }
    _measuring = true; _lastResult = ''; notifyListeners();
    if (!await encoder.syncProbeStart(audio, video, localPeerId)) {
      _measuring = false; _lastResult = 'No se pudo medir.'; notifyListeners(); return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));   // each camera's noise floor / picture first
    for (var k = 0; k < _flashes; k++) {
      flash.value = true;
      await SchedulerBinding.instance.endOfFrame;                      // the white frame is out
      await encoder.syncProbeMark();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      flash.value = false;
      await Future<void>.delayed(const Duration(milliseconds: 850));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final r = await encoder.syncProbeFinish();
    _measuring = false;
    final parts = <String>[], missed = <String>[];
    for (final id in {...audio.keys, ...video.keys}) {
      final d = r[id];
      final name = roomHost.room.peers[id]?.name ?? id;
      if (d != null) detail[id] = d;
      final v = d?.video, a = d?.audio;
      if (id == localPeerId) {
        if (v != null) { measured[id] = v; parts.add('$name $v ms'); }
        continue;
      }
      // The picture is what is aligned; its audio rides with it (WebRTC lip-syncs them).
      final ms = v ?? a;
      if (ms == null) { missed.add(name); continue; }
      measured[id] = ms;
      parts.add('$name ${v != null ? 'imagen $v ms' : 'sin destello'}${a != null ? ' · audio $a ms' : ''}');
    }
    _lastResult = [
      if (parts.isNotEmpty) 'Medido: ${parts.join(' · ')}.',
      if (missed.isNotEmpty) 'Sin medir: ${missed.join(', ')} (que vean esta pantalla, acercalas o subí el volumen).',
    ].join(' ');
    debugPrint('[SourceSync] $r → $_lastResult');
    notifyListeners();
  }

  void forget(String peerId) { measured.remove(peerId); detail.remove(peerId); notifyListeners(); }

  @override
  void dispose() {
    subscriber.removeListener(notifyListeners);
    flash.dispose();
    super.dispose();
  }
}
