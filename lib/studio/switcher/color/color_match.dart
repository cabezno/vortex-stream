import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../encode/program_encoder.dart';
import '../room/room_host.dart';

/// What the user set for one camera (all 0 = as it comes).
class CamColor {
  double exposure = 0;      // -1‥1 → ×0.71‥×1.41
  double temperature = 0;   // -1 cooler ‥ 1 warmer
  double tint = 0;          // -1 greener ‥ 1 more magenta
  double saturation = 0;    // -1 grey ‥ 1 vivid
  bool auto = false;        // match the reference camera on its own

  bool get isNeutral => exposure == 0 && temperature == 0 && tint == 0 && saturation == 0 && !auto;
  void reset() { exposure = 0; temperature = 0; tint = 0; saturation = 0; auto = false; }
}

/// Makes the cameras look alike in the program (2026-10-19). Phones of different brands see the same scene with a
/// different white balance and exposure, and a cut from one to the other showed it. Each camera gets a correction —
/// per-channel gains and saturation, applied on the switcher's GPU to the program (and on the monitor here):
/// - by hand: exposure, temperature, tint, saturation;
/// - automatic: its average colour and brightness are matched to the REFERENCE camera's, gently (partial strength,
///   clamped, smoothed) — the cameras frame different things, so a full match would chase the content.
class ColorMatch extends ChangeNotifier {
  final ProgramEncoder encoder;
  final RoomHost roomHost;
  final int? Function(String peerId) textureOf;

  ColorMatch({required this.encoder, required this.roomHost, required this.textureOf}) {
    _timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _tick());
  }

  final Map<String, CamColor> _settings = {};
  CamColor of(String peerId) => _settings.putIfAbsent(peerId, CamColor.new);

  String? _reference;
  /// The camera the others are matched to (the first one until chosen).
  String? get reference {
    final cams = roomHost.cameras;
    if (_reference != null && cams.any((c) => c.id == _reference)) return _reference;
    return cams.isEmpty ? null : cams.first.id;
  }
  set reference(String? id) { _reference = id; changed(); }

  Timer? _timer;
  bool _busy = false;
  Map<String, int> _lastMeters = {};
  Map<String, List<double>> _lastSent = {};
  final Map<String, List<double>> _autoGain = {};    // smoothed r, g, b of the automatic match
  Map<String, List<double>> _grades = {};

  /// [r, g, b, saturation] of [peerId], or null when it is left as it comes.
  List<double>? gradeOf(String? peerId) => peerId == null ? null : _grades[peerId];

  /// The same correction for a Flutter view of the camera (the monitor).
  ColorFilter? filterOf(String? peerId) {
    final g = gradeOf(peerId);
    if (g == null) return null;
    final r = g[0], gg = g[1], b = g[2], s = g[3];
    // saturation(s) · diag(r, g, b), Rec. 709 luma — the same as the GPU shader.
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final a = 1 - s;
    return ColorFilter.matrix(<double>[
      (a * lr + s) * r, a * lg * gg, a * lb * b, 0, 0,
      a * lr * r, (a * lg + s) * gg, a * lb * b, 0, 0,
      a * lr * r, a * lg * gg, (a * lb + s) * b, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }

  /// A setting changed: recompute and send now.
  void changed() { _recompute(); notifyListeners(); }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      // Meters only on the cameras that need one: automatic ones and their reference.
      final cams = roomHost.cameras;
      final ref = reference;
      final wanted = <String, int>{};
      final anyAuto = cams.any((c) => c.id != ref && (_settings[c.id]?.auto ?? false));
      for (final c in cams) {
        if (!anyAuto || !(c.id == ref || (_settings[c.id]?.auto ?? false))) continue;
        final t = textureOf(c.id);
        if (t != null && t >= 0) wanted[c.id] = t;
      }
      // The grades travel by meter (it knows the camera's track): any camera with a setting needs one too.
      for (final c in cams) {
        if (_settings[c.id]?.isNeutral ?? true) continue;
        final t = textureOf(c.id);
        if (t != null && t >= 0) wanted[c.id] = t;
      }
      if (!mapEquals(wanted, _lastMeters)) {
        _lastMeters = wanted;
        await encoder.setColorMeters(wanted);
        _lastSent = {};                                // the tracks may have changed: send the grades again
      }
      if (anyAuto && ref != null) {
        final stats = await encoder.getColorStats();
        final rs = stats[ref];
        if (rs != null) {
          final refRgb = _rgb(rs);
          for (final c in cams) {
            if (c.id == ref || !(_settings[c.id]?.auto ?? false)) continue;
            final cs = stats[c.id];
            if (cs == null) continue;
            final target = _match(refRgb, rs[0], _rgb(cs), cs[0]);
            final cur = _autoGain[c.id] ?? [1.0, 1.0, 1.0];
            _autoGain[c.id] = [for (var i = 0; i < 3; i++) cur[i] + (target[i] - cur[i]) * 0.25];
          }
        }
      }
      if (_recompute()) notifyListeners();
    } catch (e) {
      debugPrint('[ColorMatch] $e');
    } finally {
      _busy = false;
    }
  }

  /// Mean Y/U/V (BT.601, 0–255) → linear-ish RGB means.
  static List<double> _rgb(List<double> yuv) {
    final y = yuv[0], u = yuv[1] - 128, v = yuv[2] - 128;
    return [
      math.max(1, y + 1.402 * v),
      math.max(1, y - 0.344 * u - 0.714 * v),
      math.max(1, y + 1.772 * u),
    ];
  }

  /// Gains that bring [cam]'s balance and brightness toward [ref]'s, at partial strength and clamped.
  static List<double> _match(List<double> ref, double refY, List<double> cam, double camY) {
    double p(double x, double e, double lo, double hi) => math.pow(x, e).toDouble().clamp(lo, hi);
    final wr = p((ref[0] / ref[1]) / (cam[0] / cam[1]), 0.8, 0.75, 1.33);
    final wb = p((ref[2] / ref[1]) / (cam[2] / cam[1]), 0.8, 0.75, 1.33);
    final ex = p(math.max(refY, 1) / math.max(camY, 1), 0.6, 0.8, 1.25);
    return [wr * ex, ex, wb * ex];
  }

  /// True when the grades changed.
  bool _recompute() {
    final out = <String, List<double>>{};
    for (final c in roomHost.cameras) {
      final s = _settings[c.id];
      if (s == null) continue;
      final auto = s.auto && c.id != reference ? (_autoGain[c.id] ?? const [1.0, 1.0, 1.0]) : const [1.0, 1.0, 1.0];
      final e = math.pow(2, s.exposure * 0.5).toDouble();
      final r = auto[0] * e * (1 + 0.15 * s.temperature);
      final g = auto[1] * e * (1 - 0.10 * s.tint);
      final b = auto[2] * e * (1 - 0.15 * s.temperature);
      final sat = (1 + s.saturation * 0.8).clamp(0.0, 1.8);
      final v = [r, g, b, sat];
      if (v.every((x) => (x - 1).abs() < 0.005)) continue;
      out[c.id] = v;
    }
    _grades = out;
    bool same(Map<String, List<double>> a, Map<String, List<double>> b) => a.length == b.length &&
        a.entries.every((e) => b[e.key] != null &&
            Iterable<int>.generate(4).every((i) => (e.value[i] - b[e.key]![i]).abs() < 0.003));
    if (same(out, _lastSent)) return false;
    _lastSent = out;
    encoder.setColorGrades(out);
    return true;
  }

  @override
  void dispose() {
    _timer?.cancel();
    encoder.setColorGrades({});
    encoder.setColorMeters({});
    super.dispose();
  }
}
