import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:samba_protocol/samba_protocol.dart';

enum CameraFacing { front, back }

/// WebRTC publisher of a Studio camera: ONE video stream whose quality the switcher sets (set_layer, PGM/PVW
/// 2026-10-06): high (capture size, up to 6 Mbps, 30 fps) while on air / in preview / second camera of a split,
/// low (360p, 600 kbps, 15 fps) otherwise. Changing it only re-configures the encoder (a key frame, no renegotiation).
class WebRtcPublisher {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  RTCRtpTransceiver? _videoTransceiver;
  Timer? _statsTimer;
  Layer _currentLayer = Layer.low;
  int _currentHeight = 1080;               // height asked with the high layer (1080 / 2160)
  int _captureHeight = SimulcastLayers.highHeight;
  /// Requested capture size: 1080p, raised to 4K the first time the switcher asks it (and kept for the session —
  /// re-opening the camera at every cut would freeze the picture for a moment).
  int _captureW = SimulcastLayers.highWidth, _captureH = SimulcastLayers.highHeight;

  /// A camera chosen by id (a USB camera / HDMI capture, or a specific lens): overrides [CameraFacing].
  String? deviceId;

  /// Highest height this phone can send (its hardware encoder AND its camera, measured — DeviceCapabilities).
  int maxHeight = 1080;

  /// Called after the camera was re-opened at another size (4K), so the UI re-points its preview.
  void Function(MediaStream stream)? onCaptureChanged;
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
  /// Height being sent now (after the switcher's order and this phone's limits).
  int get sentHeight => _sentHeight;
  int _sentHeight = 0;
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
        if (deviceId != null) 'deviceId': deviceId
        else 'facingMode': facing == CameraFacing.back ? 'environment' : 'user',
        // Plain numbers, not {'ideal': N}: flutter_webrtc (GetUserMediaImpl.getConstrainInt, 1.6.2) looks for "ideal"
        // in the OUTER map, so a map is ignored and it falls back to its 1280x720 default — that is why WHIP and the
        // Studio camera always arrived at 720p (found 2026-10-04). A number is a target: the camera takes the closest
        // format it supports.
        'width': _captureW,
        'height': _captureH,
        'frameRate': {'ideal': 30, 'min': 15},
      },
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    // The size the camera really gave (the low layer is a fraction of it).
    try {
      final st = _localStream!.getVideoTracks().first.getSettings();
      final w = (st['width'] as num?)?.toInt(), h = (st['height'] as num?)?.toInt();
      if (w != null && h != null && w > 0 && h > 0) _captureHeight = w < h ? w : h;
    } catch (_) {}
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
      // Quality of the layer the switcher asked for (low until it says otherwise).
      await _applyLayerParams();
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

  /// Switcher's order: high or low quality, and for high the wanted height (see the class comment).
  Future<void> setLayer(Layer layer, {int height = 1080}) async {
    _currentLayer = layer;
    _currentHeight = height;
    // 4K asked and this phone can: re-open the camera at 4K once (replaceTrack, no renegotiation).
    if (layer == Layer.high && height >= SimulcastLayers.uhdHeight && maxHeight >= SimulcastLayers.uhdHeight &&
        _captureH < SimulcastLayers.uhdHeight && _peerConnection != null) {
      _captureW = SimulcastLayers.uhdWidth;
      _captureH = SimulcastLayers.uhdHeight;
      try {
        final s = await switchCamera(_facing);
        onCaptureChanged?.call(s);
        debugPrint('[WebRtcPublisher] cámara reabierta en ${_captureHeight}p para el programa 4K');
      } catch (e) {
        debugPrint('[WebRtcPublisher] no se pudo abrir la cámara en 4K: $e');
        _captureW = SimulcastLayers.highWidth; _captureH = SimulcastLayers.highHeight;
      }
    }
    await _applyLayerParams();
  }

  /// Applies [_currentLayer] to the single video encoding.
  /// - high: full capture size; ceiling 6 Mbps (WebRTC's default caps 1080p at ~2.5 Mbps and the program looked soft);
  ///   floor 3.5 Mbps (on Wi-Fi ~1 % loss made the estimate fall to 300–700 kbps and the on-air camera arrived at
  ///   640x360, measured 2026-10-04 — on a LAN that loss does not justify it).
  /// - low: scaled to ~360p (the factor is measured from what the camera captures), 600 kbps, 15 fps.
  /// Keys are always set: flutter_webrtc leaves a parameter unchanged when it is missing from the map.
  Future<void> _applyLayerParams() async {
    final t = _videoTransceiver;
    if (t == null) return;
    try {
      final params = t.sender.parameters;
      final encs = params.encodings;
      if (encs == null || encs.isEmpty) return;
      final high = _currentLayer == Layer.high;
      final target = high ? _currentHeight.clamp(SimulcastLayers.lowHeight, maxHeight) : SimulcastLayers.lowHeight;
      final scale = _captureHeight <= target ? 1.0 : _captureHeight / target;
      final sent = (_captureHeight / scale).round();
      final uhd = high && sent >= SimulcastLayers.uhdHeight;
      final maxBps = !high ? SimulcastLayers.lowMaxBitrate : uhd ? SimulcastLayers.uhdMaxBitrate : SimulcastLayers.highMaxBitrate;
      final minBps = !high ? 100000 : uhd ? SimulcastLayers.uhdMinBitrate : SimulcastLayers.highMinBitrate;
      for (final e in encs) {
        e.active = true;
        e.scaleResolutionDownBy = scale;
        e.maxBitrate = maxBps;
        e.minBitrate = minBps;
        e.maxFramerate = high ? SimulcastLayers.highMaxFramerate : SimulcastLayers.lowMaxFramerate;
      }
      await t.sender.setParameters(params);
      _sentHeight = sent;
      debugPrint('[WebRtcPublisher] capa ${high ? 'ALTA' : 'BAJA'}: ${sent}p, hasta ${maxBps ~/ 1000} kbps');
    } catch (e) {
      debugPrint('[WebRtcPublisher] no se pudo aplicar la capa ${_currentLayer.name}: $e');
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
