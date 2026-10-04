import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:samba_protocol/samba_protocol.dart';

enum CameraFacing { front, back }

/// WebRTC Publisher that captures camera/mic and advertises Simulcast:
/// - rid 'low': ~320x180, 15fps, 150kbps (Always on, for switcher multiview)
/// - rid 'high': ~1280x720, 30fps, 3Mbps (Activated when this camera is ON-AIR)
class WebRtcPublisher {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCRtpTransceiver? _videoTransceiver;
  Timer? _statsTimer;
  Layer _currentLayer = Layer.low;
  CameraFacing _facing = CameraFacing.back;
  bool _encoderKickChecked = false;

  /// H.264 (the phone's HARDWARE encoder) is tried first: VP8 is software and a phone's CPU tops out around 720p30
  /// (Xiaomi measured 2026-10-04: qualityLimitationReason=cpu, 1080p capture sent as 720p). If the H.264 encoder does
  /// not start (framesEncoded=0 after connecting — the Galaxy A10 / Exynos case that made VP8 the default on
  /// 2026-09-29), this flips to VP8 for the rest of the app's life and asks for a new session. Detected live, never
  /// from a list of phones.
  static bool _h264Failed = false;
  bool _usingH264 = false;

  /// Called when the session must be renegotiated (new offer), e.g. after falling back from H.264 to VP8.
  Future<void> Function()? onRenegotiate;

  /// Se dispara cuando el "destrabe" del encoder re-adquiere la cámara, para que
  /// la UI re-apunte su preview al nuevo stream.
  void Function(MediaStream stream)? onLocalStreamReplaced;

  RTCPeerConnection? get peerConnection => _peerConnection;
  MediaStream? get localStream => _localStream;
  Layer get currentLayer => _currentLayer;
  bool get isHighActive => _currentLayer == Layer.high;

  /// Callback when a local ICE candidate is gathered
  void Function(RTCIceCandidate candidate)? onIceCandidate;

  /// Callback when ICE connection state changes
  void Function(RTCIceConnectionState state)? onIceConnectionState;

  /// Initialize local camera & microphone media stream
  Future<MediaStream> initMediaStream({
    CameraFacing facing = CameraFacing.back,
  }) async {
    _facing = facing;
    _localStream?.getTracks().forEach((t) => t.stop());

    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': {
        'facingMode': facing == CameraFacing.back ? 'environment' : 'user',
        // Plain numbers, not {'ideal': N}: flutter_webrtc (GetUserMediaImpl.getConstrainInt, 1.6.2) looks for "ideal"
        // in the OUTER map, so a map is ignored and it falls back to its 1280x720 default — that is why WHIP and the
        // Studio camera always arrived at 720p (found 2026-10-04). A number is a target: the camera takes the closest
        // format it supports.
        'width': SimulcastLayers.highWidth,
        'height': SimulcastLayers.highHeight,
        'frameRate': {'ideal': 30, 'min': 15},
      },
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    return _localStream!;
  }

  /// Create WebRTC PeerConnection configured for Simulcast
  Future<void> createPeerConnectionSession() async {
    // RECONEXIÓN: cerrar el PeerConnection viejo ANTES de crear uno nuevo. Si no,
    // el sender/encoder viejo sigue "dueño" del track de la cámara y el encoder
    // del PC nuevo nunca recibe frames (framesEncoded=0). Pasaba al reconectar
    // tras reiniciar el switcher. El track/cámara sigue vivo (no se detiene).
    _statsTimer?.cancel();
    _statsTimer = null;
    _encoderKickChecked = false;
    if (_peerConnection != null) {
      await _peerConnection!.close();
      _peerConnection = null;
      _videoTransceiver = null;
    }

    if (_localStream == null) {
      await initMediaStream();
    }

    final rtcConfig = <String, dynamic>{
      'iceServers': [
        // Primary LAN operation, fallback to public STUN
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(rtcConfig);

    _peerConnection!.onIceCandidate = (candidate) {
      onIceCandidate?.call(candidate);
    };

    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('[WebRtcPublisher] ICE state: $state');
      onIceConnectionState?.call(state);
    };

    _peerConnection!.onConnectionState = (state) {
      debugPrint('[WebRtcPublisher] PeerConnection state: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          !_encoderKickChecked) {
        _encoderKickChecked = true;
        _maybeKickEncoder();
      }
    };

    _peerConnection!.onIceGatheringState = (state) {
      debugPrint('[WebRtcPublisher] ICE gathering: $state');
    };

    // Add audio track
    for (final track in _localStream!.getAudioTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    // Video: transceiver sendrecv single-stream (SIN simulcast) FORZANDO VP8.
    // DIAGNÓSTICO 2026-09-29: con addTransceiver+simulcast Y con addTrack simple el
    // encoder JAMÁS se instanciaba (framesEncoded=0, sin log de HardwareVideoEncoder)
    // aunque la cámara capturaba 25fps y el preview local renderizaba. El factor común
    // era el codec: se negociaba H264 y el encoder HW del teléfono no arrancaba en
    // silencio. VP8 es encoder software universal → arranca siempre en LAN.
    for (final track in _localStream!.getVideoTracks()) {
      final transceiver = await _peerConnection!.addTransceiver(
        track: track,
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        // streams: asocia el track de video al MediaStream → genera msid en el SDP.
        // SIN esto el switcher recibía el track de video con event.streams VACÍO y
        // no podía renderizarlo (lo metía en un stream local irresoluble → 0 frames
        // en pantalla aunque WebRTC lo decodificara). El audio sí se veía porque
        // addTrack ya llevaba el stream. Ahora video y audio comparten msid.
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: [_localStream!],
        ),
      );
      _videoTransceiver = transceiver;
      try {
        final caps = await getRtpSenderCapabilities('video');
        final all = caps.codecs ?? [];
        // H.264 first (hardware) unless it already failed on this phone, then VP8 (+ RTX).
        String m(RTCRtpCodecCapability c) => c.mimeType.toUpperCase();
        final h264 = _h264Failed ? <RTCRtpCodecCapability>[] : all.where((c) => m(c) == 'VIDEO/H264').toList();
        final preferred = [
          ...h264,
          ...all.where((c) => m(c) == 'VIDEO/VP8'),
          ...all.where((c) => m(c) == 'VIDEO/RTX'),
        ];
        _usingH264 = h264.isNotEmpty;
        final hasVp8 =
            preferred.any((c) => m(c) == 'VIDEO/VP8');
        debugPrint(
            '[WebRtcPublisher] codecs disponibles: ${all.map((c) => c.mimeType).join(", ")}');
        if (hasVp8 || _usingH264) {
          await transceiver.setCodecPreferences(preferred);
          debugPrint(
              '[WebRtcPublisher] Codec preference => ${_usingH264 ? 'H264 (hardware) → VP8' : 'VP8'} (${preferred.length} entradas)');
        } else {
          debugPrint(
              '[WebRtcPublisher] VP8 no disponible, se deja negociación por defecto');
        }
      } catch (e) {
        debugPrint('[WebRtcPublisher] setCodecPreferences falló: $e');
      }
      // Bitrate ceiling: without it WebRTC caps 720p VP8 at ~2.5 Mbps (default) and the program looks soft.
      try {
        final params = transceiver.sender.parameters;
        final encs = params.encodings;
        if (encs != null && encs.isNotEmpty) {
          for (final e in encs) {
            e.maxBitrate = SimulcastLayers.highMaxBitrate;
            // Floor: on Wi-Fi ~1 % packet loss made WebRTC's loss-based estimate fall to 300–700 kbps and the
            // on-air camera reached the switcher at 640x360 (measured 2026-10-04, Xiaomi → A10). On a LAN that
            // loss does not justify it; the floor keeps the picture (same as the WHIP path's 1.5 Mbps floor).
            e.minBitrate = SimulcastLayers.highMinBitrate;
            e.maxFramerate = SimulcastLayers.highMaxFramerate;
          }
          await transceiver.sender.setParameters(params);
          debugPrint('[WebRtcPublisher] maxBitrate ${SimulcastLayers.highMaxBitrate ~/ 1000} kbps');
        }
      } catch (e) {
        debugPrint('[WebRtcPublisher] setParameters (bitrate) falló: $e');
      }
    }

    // DIAGNÓSTICO: log de stats de envío de video cada 3s
    _statsTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      final pc = _peerConnection;
      if (pc == null) {
        t.cancel();
        return;
      }
      try {
        final reports = await pc.getStats();
        for (final r in reports) {
          final v = r.values;
          if (r.type == 'outbound-rtp' &&
              (v['mediaType'] == 'video' || v['kind'] == 'video')) {
            debugPrint(
                '[Publisher STATS] framesEncoded=${v['framesEncoded']} framesSent=${v['framesSent']} bytesSent=${v['bytesSent']} qpSum=${v['qpSum']} active=${v['active']} '
                'size=${v['frameWidth']}x${v['frameHeight']} limit=${v['qualityLimitationReason']}');
          }
          if (r.type == 'media-source' &&
              (v['mediaType'] == 'video' || v['kind'] == 'video')) {
            debugPrint(
                '[MediaSource STATS] frames=${v['frames']} fps=${v['framesPerSecond']} w=${v['width']} h=${v['height']}');
          }
        }
      } catch (_) {}
    });
  }

  /// Create local SDP Offer
  Future<RTCSessionDescription> createOffer() async {
    if (_peerConnection == null) {
      throw StateError('PeerConnection not initialized');
    }

    // Sin constraints legacy: con unified-plan las direcciones las definen los
    // transceivers (addTrack = sendrecv). Pasar offerToReceiveVideo:false rompía
    // el m-line de video y el encoder no arrancaba (0 frames enviados).
    final offer = await _peerConnection!.createOffer({});
    await _peerConnection!.setLocalDescription(offer);
    _logSdpCodecs('OFFER', offer.sdp);
    return offer;
  }

  /// Loguea solo las líneas de codec/dirección del m=video de una SDP.
  void _logSdpCodecs(String label, String? sdp) {
    if (sdp == null) return;
    final lines = sdp.split('\n');
    var inVideo = false;
    for (final raw in lines) {
      final l = raw.trim();
      if (l.startsWith('m=')) inVideo = l.startsWith('m=video');
      if (!inVideo) continue;
      if (l.startsWith('m=video') ||
          l.startsWith('a=rtpmap') ||
          l.startsWith('a=sendrecv') ||
          l.startsWith('a=sendonly') ||
          l.startsWith('a=recvonly') ||
          l.startsWith('a=inactive')) {
        debugPrint('[SDP $label] $l');
      }
    }
  }

  /// Set remote SDP Answer received from Switcher
  Future<void> setRemoteAnswer(String sdp) async {
    if (_peerConnection == null) return;
    _logSdpCodecs('ANSWER', sdp);
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    await _dumpSendState('post-answer');
  }

  /// DIAGNÓSTICO: vuelca el estado de senders/transceivers para ver si el
  /// video realmente quedó con track y dirección de envío.
  Future<void> _dumpSendState(String when) async {
    final pc = _peerConnection;
    if (pc == null) return;
    try {
      final senders = await pc.getSenders();
      for (final s in senders) {
        debugPrint(
            '[SEND $when] sender kind=${s.track?.kind} trackId=${s.track?.id} enabled=${s.track?.enabled}');
      }
      final trans = await pc.getTransceivers();
      for (final t in trans) {
        debugPrint(
            '[SEND $when] transceiver mid=${t.mid} senderTrackKind=${t.sender.track?.kind} receiverTrackKind=${t.receiver.track?.kind}');
      }
    } catch (e) {
      debugPrint('[SEND $when] error: $e');
    }
  }

  /// Add remote ICE candidate
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (_peerConnection == null) return;
    await _peerConnection!.addCandidate(candidate);
  }

  /// Dynamically toggle high-definition layer on command from Switcher
  Future<void> setLayer(Layer layer) async {
    _currentLayer = layer;
    if (_videoTransceiver == null) return;

    try {
      final sender = _videoTransceiver!.sender;
      final parameters = sender.parameters;
      final encodings = parameters.encodings;

      if (encodings != null && encodings.length >= 2) {
        // Encoding 0 = low (always active)
        encodings[0].active = true;
        // Encoding 1 = high (active only if Layer.high)
        encodings[1].active = (layer == Layer.high);

        await sender.setParameters(parameters);
        debugPrint('[WebRtcPublisher] Switched layer to ${layer.name} (high active: ${encodings[1].active})');
      }
    } catch (e) {
      debugPrint('[WebRtcPublisher] Error setting layer parameters: $e');
    }
  }

  /// Destrabe automático del encoder: en algunos equipos la sesión se CONECTA
  /// pero el encoder no arranca (framesEncoded=0 → "conecta pero no transmite");
  /// re-adquirir la cámara + replaceTrack lo destraba (era lo que hacía el flip
  /// manual). A los ~4s de conectar, si sigue en 0 frames, re-adquiere solo.
  Future<void> _maybeKickEncoder() async {
    await Future.delayed(const Duration(seconds: 4));
    final pc = _peerConnection;
    if (pc == null) return;
    int encoded = -1;
    try {
      final reports = await pc.getStats();
      for (final r in reports) {
        final v = r.values;
        if (r.type == 'outbound-rtp' &&
            (v['mediaType'] == 'video' || v['kind'] == 'video')) {
          encoded = (v['framesEncoded'] as num?)?.toInt() ?? 0;
        }
      }
    } catch (_) {}
    if (encoded == 0 && _usingH264 && !_h264Failed && onRenegotiate != null) {
      // The hardware H.264 encoder did not start: VP8 from now on, new session.
      _h264Failed = true;
      debugPrint('[WebRtcPublisher] H.264 por hardware no arrancó (framesEncoded=0) → VP8 y renegocio');
      try { await onRenegotiate!(); } catch (e) { debugPrint('[WebRtcPublisher] renegociar falló: $e'); }
    } else if (encoded == 0) {
      debugPrint(
          '[WebRtcPublisher] encoder no arrancó (framesEncoded=0) → re-adquiriendo cámara (auto-kick)');
      try {
        final fresh = await switchCamera(_facing);
        onLocalStreamReplaced?.call(fresh);
      } catch (e) {
        debugPrint('[WebRtcPublisher] auto-kick falló: $e');
      }
    } else {
      debugPrint('[WebRtcPublisher] encoder OK (framesEncoded=$encoded), sin kick');
    }
  }

  /// Gira la cámara (frontal/trasera) re-abriendo el capturer y RE-CABLEANDO los
  /// senders con replaceTrack (sin renegociar). Historia: (1) el flip original
  /// hacía getUserMedia nuevo pero NO actualizaba el sender → el switcher se iba
  /// a negro; (2) Helper.switchCamera (giro in-place del mismo track) dejaba el
  /// capturer MUERTO en 0 frames en algunos Xiaomi/MIUI. Esta versión recrea el
  /// stream (capturer fresco, confiable) y hace replaceTrack en los senders:
  /// el switcher recibe la nueva cámara sin cortar la sesión.
  Future<MediaStream> switchCamera(CameraFacing facing) async {
    final newStream = await initMediaStream(facing: facing);
    final senders = await _peerConnection?.getSenders() ?? [];
    for (final s in senders) {
      final kind = s.track?.kind;
      if (kind == 'video' && newStream.getVideoTracks().isNotEmpty) {
        await s.replaceTrack(newStream.getVideoTracks().first);
      } else if (kind == 'audio' && newStream.getAudioTracks().isNotEmpty) {
        await s.replaceTrack(newStream.getAudioTracks().first);
      }
    }
    return newStream;
  }

  /// Dispose media and WebRTC session
  Future<void> dispose() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream = null;
    await _peerConnection?.close();
    _peerConnection = null;
    _videoTransceiver = null;
  }
}
