// What THIS phone can do, measured on the phone — the app offers only the transports that work, and greys out the
// rest WITH the reason, so the user never finds out live (2026-10-04).
//
// Native probe (DeviceCaps.kt): hardware H.264 / H.265 encoders and their largest size at 30 / 60 fps, cameras, OMT's
// CPU encoder speed. Here: WHIP needs H.264 INSIDE WebRTC (SAMBA's WHIP receiver takes H.264/H.265 only), which some
// phones can't start (Galaxy A10 / Exynos: framesEncoded stays 0) — checked with a few-second loopback session.
// Cached per Android build + APK install time: probed again after any update. Never a list of phone models.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection_config.dart';

class TransportSupport {
  final bool ok;
  final String reason;   // why not, when !ok; empty when ok
  final String detail;   // e.g. "hasta 3840x2160 @ 30"
  const TransportSupport(this.ok, {this.reason = '', this.detail = ''});
}

class DeviceCapabilities extends ChangeNotifier {
  DeviceCapabilities._();
  static final DeviceCapabilities instance = DeviceCapabilities._();

  static const _channel = MethodChannel('com.vortex.vortexcam/native');
  static const _prefsKey = 'device_caps_v1';

  Map<String, dynamic>? _caps;
  bool _probing = false;
  bool get ready => _caps != null;
  bool get probing => _probing;
  Map<String, dynamic> get raw => _caps ?? const {};

  /// Cached result if Android and the app did not change since; otherwise probes (a few seconds, once).
  /// Needs the camera permission for the WebRTC check (without it, WHIP is assumed possible and verified live).
  Future<void> ensure({bool cameraGranted = true}) async {
    if (_probing) return;
    String stamp = '';
    try { stamp = await _channel.invokeMethod<String>('capsStamp') ?? ''; } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_prefsKey);
      if (cached != null) {
        final m = jsonDecode(cached) as Map<String, dynamic>;
        if (m['stamp'] == stamp && stamp.isNotEmpty && (m['webrtcChecked'] == true || !cameraGranted)) {
          _caps = m; notifyListeners(); return;
        }
      }
    } catch (_) {}
    _probing = true; notifyListeners();
    try {
      final native = Map<String, dynamic>.from(
          (await _channel.invokeMethod<Map>('probeCapabilities')) ?? const {});
      final m = _deepCast(native);
      m['stamp'] = stamp;
      if (cameraGranted) {
        m['webrtc'] = await _probeWebrtcH264();
        m['webrtcChecked'] = (m['webrtc'] as Map)['h264'] != null;   // could not test → try again next time
      }
      _caps = m;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsKey, jsonEncode(m));
      } catch (_) {}
      debugPrint('[DeviceCaps] ${jsonEncode(m)}');
    } catch (e) {
      debugPrint('[DeviceCaps] probe failed: $e');   // unknown → everything offered, as before
    } finally {
      _probing = false; notifyListeners();
    }
  }

  /// A connection found out live that WHIP can't encode (fallback when the probe could not run): remember it.
  Future<void> markWhipUnsupported(String reason) async {
    final m = Map<String, dynamic>.from(_caps ?? {});
    m['webrtc'] = {'h264': false, 'reason': reason};
    m['webrtcChecked'] = true;
    _caps = m; notifyListeners();
    try { (await SharedPreferences.getInstance()).setString(_prefsKey, jsonEncode(m)); } catch (_) {}
  }

  // ---- What the UI asks ----------------------------------------------------------------------------------------

  Map<String, dynamic>? _enc(String k) => (raw[k] is Map) ? Map<String, dynamic>.from(raw[k]) : null;
  bool get hasHevc => _enc('hevc') != null;
  String? get maxH264 => _enc('avc')?['max30'] as String?;
  String? get maxHevc => _enc('hevc')?['max30'] as String?;
  String? get cameraMax => (raw['cameraBack'] is Map) ? raw['cameraBack']['max'] as String? : null;

  /// Shorter side of a "WxH" string (2160 for "3840x2160"), 0 if unknown.
  static int heightOf(String? wxh) {
    final m = RegExp(r'(\d+)x(\d+)').firstMatch(wxh ?? '');
    if (m == null) return 0;
    final a = int.parse(m[1]!), b = int.parse(m[2]!);
    return a < b ? a : b;
  }

  /// Highest height this phone can SEND as a camera: its hardware H.264 encoder at 30 fps and its back camera, the
  /// smaller of the two. 1080 when not measured (what every phone tested does).
  int get maxSendHeight {
    final enc = heightOf(maxH264), cam = heightOf(cameraMax);
    if (enc == 0) return 1080;
    return cam == 0 ? enc : (enc < cam ? enc : cam);
  }

  /// Highest height this phone can ENCODE as a switcher program (its hardware H.264 encoder at 30 fps).
  int get maxProgramHeight {
    final enc = heightOf(maxH264);
    return enc == 0 ? 1080 : enc;
  }

  TransportSupport support(Transport t) {
    if (!ready) return const TransportSupport(true);       // not measured: offer it (as before)
    final h264 = _enc('avc');
    final hw = h264 != null ? 'hasta ${h264['max30']} @ 30' : '';
    switch (t) {
      case Transport.whip:
        final w = (raw['webrtc'] is Map) ? Map<String, dynamic>.from(raw['webrtc']) : null;
        if (w == null || w['h264'] == null) return TransportSupport(true, detail: hw);   // not tested: verified live
        if (w['h264'] == true) return TransportSupport(true, detail: 'encoder ${w['encoder'] ?? 'H.264'}');
        return TransportSupport(false,
            reason: 'Este celular no puede H.264 dentro de WebRTC (${w['reason'] ?? 'el encoder no arranca'}). '
                'Usá SBL o SRT.');
      case Transport.omt:
        final o = (raw['omt'] is Map) ? Map<String, dynamic>.from(raw['omt']) : null;
        if (o == null || o['available'] != true) {
          return TransportSupport(false, reason: 'OMT no disponible: ${o?['reason'] ?? 'sin encoder VMX'}.');
        }
        final fps = (o['fps1080'] as num?)?.toInt() ?? 0;
        if (fps < 15) {
          return TransportSupport(false,
              reason: 'OMT codifica con la CPU y este celular saca $fps fps en 1080p (mínimo 15). Usá SBL o SRT.');
        }
        return TransportSupport(true, detail: '$fps fps en 1080p (CPU)');
      case Transport.srt:
      case Transport.rtmp:
      case Transport.sbl:
        if (h264 == null) {
          return const TransportSupport(false, reason: 'Este celular no tiene encoder H.264 por hardware.');
        }
        return TransportSupport(true, detail: hw);
    }
  }

  /// First transport of [candidates] this phone supports (QR order is SAMBA's preference), or null.
  Transport? firstSupported(List<Transport> candidates) {
    for (final t in candidates) { if (support(t).ok) return t; }
    return null;
  }

  /// One line for the UI: what the phone can do.
  String summary() {
    if (!ready) return probing ? 'Midiendo qué puede hacer este celular…' : '';
    final parts = <String>[
      if (maxH264 != null) 'H.264 hasta $maxH264',
      if (maxHevc != null) 'H.265 hasta $maxHevc',
      if (cameraMax != null) 'cámara $cameraMax',
    ];
    return parts.join(' · ');
  }

  // ---- WebRTC H.264 loopback check -------------------------------------------------------------------------------

  Future<Map<String, dynamic>> _probeWebrtcH264() async {
    MediaStream? s;
    RTCPeerConnection? a, b;
    try {
      final caps = await getRtpSenderCapabilities('video');
      final h264 = (caps.codecs ?? []).where((c) => c.mimeType.toUpperCase() == 'VIDEO/H264').toList();
      if (h264.isEmpty) return {'h264': false, 'reason': 'WebRTC no ofrece H.264'};
      s = await navigator.mediaDevices.getUserMedia({'audio': false, 'video': {'width': 640, 'height': 480}})
          .timeout(const Duration(seconds: 8));
      a = await createPeerConnection({'sdpSemantics': 'unified-plan'});
      b = await createPeerConnection({'sdpSemantics': 'unified-plan'});
      final pa = a, pb = b;
      pa.onIceCandidate = (c) => pb.addCandidate(c);
      pb.onIceCandidate = (c) => pa.addCandidate(c);
      final tr = await pa.addTransceiver(
        track: s.getVideoTracks().first,
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly),
      );
      await tr.setCodecPreferences(h264);
      final offer = await pa.createOffer({});
      await pa.setLocalDescription(offer);
      await pb.setRemoteDescription(offer);
      final answer = await pb.createAnswer({});
      await pb.setLocalDescription(answer);
      await pa.setRemoteDescription(answer);
      for (int i = 0; i < 16; i++) {                           // up to 8 s
        await Future.delayed(const Duration(milliseconds: 500));
        for (final r in await pa.getStats()) {
          final v = r.values;
          if (r.type == 'outbound-rtp' && (v['kind'] == 'video' || v['mediaType'] == 'video')) {
            final n = (v['framesEncoded'] as num?)?.toInt() ?? 0;
            if (n > 0) return {'h264': true, 'encoder': v['encoderImplementation'] ?? ''};
          }
        }
      }
      return {'h264': false, 'reason': 'el encoder H.264 no arrancó'};
    } catch (e) {
      return {'h264': null, 'reason': 'no se pudo probar: $e'};   // unknown → offered, verified live
    } finally {
      try { await a?.close(); } catch (_) {}
      try { await b?.close(); } catch (_) {}
      try { s?.getTracks().forEach((t) => t.stop()); await s?.dispose(); } catch (_) {}
    }
  }

  static Map<String, dynamic> _deepCast(Map m) => m.map((k, v) =>
      MapEntry(k.toString(), v is Map ? _deepCast(v) : v));
}
