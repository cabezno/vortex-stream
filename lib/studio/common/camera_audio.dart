import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a camera phone captures its sound (2026-10-20).
/// - natural: the place as it sounds — no echo cancelling, noise suppression or automatic gain, and the phone's own
///   voice processing bypassed (plain microphone). The default: a camera is not a call, and a Redmi Note 14 Pro in
///   «call» mode cut its sound to absolute silence in every pause (its system muted ~2/3 of the captured blocks).
/// - voice: call processing (WebRTC's and the phone's): less noise and echo, for someone talking close to the phone.
enum CameraAudioMode { natural, voice }

class CameraAudio {
  static const _key = 'cam.audioMode';
  static CameraAudioMode mode = CameraAudioMode.natural;
  static bool _loaded = false;
  /// The mode the phone's audio engine was created with (null = not yet, or by someone else with the defaults).
  static CameraAudioMode? _engineMode;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      mode = p.getString(_key) == 'voice' ? CameraAudioMode.voice : CameraAudioMode.natural;
    } catch (_) {}
    _loaded = true;
  }

  static Future<void> set(CameraAudioMode m) async {
    mode = m;
    try { (await SharedPreferences.getInstance()).setString(_key, m.name); } catch (_) {}
  }

  /// getUserMedia audio constraints (WebRTC's own processing): applied at every opening of the camera.
  static Map<String, dynamic> constraints() {
    final v = mode == CameraAudioMode.voice;
    return {'echoCancellation': v, 'noiseSuppression': v, 'autoGainControl': v};
  }

  /// The phone's own processing is chosen when flutter_webrtc creates its audio engine — once per run of the app, at
  /// its first use. So this goes first thing at startup, before anything touches WebRTC.
  static Future<void> initEngine() async {
    await load();
    if (WebRTC.initialized) return;
    try {
      await WebRTC.initialize(options: {'bypassVoiceProcessing': mode == CameraAudioMode.natural});
      _engineMode = mode;
    } catch (e) {
      debugPrint('[CameraAudio] $e');
    }
  }

  /// The setting changed since the app started: the phone's part applies when the app is opened again.
  static bool get needsRestart => _engineMode != null && _engineMode != mode;
}
