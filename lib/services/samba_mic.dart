import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// «Sonido» of the camera → SAMBA mic (DT-315, 2026-10-26).
/// - natural: the place as it sounds (no processing).
/// - voice: the phone's noise suppressor (SRT / SBL / RTMP) or WebRTC's voice processing (WHIP): wins when there is
///   background noise, at the cost of a less natural sound.
/// - auto: natural, and voice by itself while there is steady background noise (MicProcessing.kt; WHIP:
///   ConnectionService).
/// voice and auto are offered only when the phone has a noise suppressor ([voiceAvailable]).
enum SambaMicMode { natural, voice, auto }

class SambaMic {
  static const _key = 'samba.micMode';
  static const _ch = MethodChannel('com.vortex.vortexcam/native');
  static SambaMicMode mode = SambaMicMode.natural;
  static bool voiceAvailable = false;
  /// WHIP in auto: voice processing on right now (decided by ConnectionService from the mic level).
  static bool autoVoice = false;

  static Future<void> load() async {
    try {
      final caps = await _ch.invokeMethod<Map>('audioCaps');
      voiceAvailable = caps?['noiseSuppressor'] == true;
    } catch (e) {
      debugPrint('[SambaMic] audioCaps: $e');
    }
    try {
      final s = (await SharedPreferences.getInstance()).getString(_key);
      mode = SambaMicMode.values.firstWhere((m) => m.name == s, orElse: () => SambaMicMode.natural);
    } catch (_) {}
    if (!voiceAvailable) mode = SambaMicMode.natural;
    await _push();
  }

  static Future<void> set(SambaMicMode m) async {
    mode = voiceAvailable ? m : SambaMicMode.natural;
    autoVoice = false;
    try { (await SharedPreferences.getInstance()).setString(_key, mode.name); } catch (_) {}
    await _push();
  }

  static Future<void> _push() async {
    try { await _ch.invokeMethod('setMicMode', {'mode': mode.name}); } catch (_) {}
  }

  static bool get voiceNow => mode == SambaMicMode.voice || (mode == SambaMicMode.auto && autoVoice);

  /// getUserMedia audio constraints for WHIP (WebRTC's own processing).
  static Map<String, dynamic> constraints({bool? voice}) {
    final v = voice ?? voiceNow;
    return {'echoCancellation': v, 'noiseSuppression': v, 'autoGainControl': v};
  }
}
