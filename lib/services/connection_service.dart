import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'camera_service.dart';
import 'device_capabilities.dart';
import 'samba_mic.dart';

// =============================================================================
// ConnectionService — manages WebRTC/WHIP connection to VortexEngine
//
// Protocol: WHIP (WebRTC-HTTP Ingest Protocol)
//   POST http://{engine_ip}:8080/whip/{source_id}
//   Body: SDP offer
//   Response: SDP answer
//
// Control channel: a WebRTC data channel 'vortex-control' (created by phone
// as offerer) carries JSON messages both ways:
//   Engine → Phone: {"type":"set_resolution","width":W,"height":H}
//   Engine → Phone: {"type":"on_air","active":true/false}
//   Engine → Phone: {"type":"pong","sentMs":T}
// =============================================================================

enum ConnectionState { disconnected, connecting, connected, error }

class ConnectionService extends ChangeNotifier {
  ConnectionState _state        = ConnectionState.disconnected;
  String _engineIp              = '';
  int    _enginePort            = 8080;
  String _sourceId              = 'cam1';
  // The WHIP resource the engine actually gave us (201 Location). With several phones SAMBA numbers the name
  // ("cam1(2)"), so the DELETE must go there, not to /whip/<sourceId> (that is another phone's session).
  String? _whipResourceUrl;
  String _sourceName            = 'Mobile Cam';
  String _errorMessage          = '';
  int    _latencyMs             = 0;
  bool   _isOnAir               = false;

  RTCPeerConnection?  _peerConnection;
  RTCDataChannel?     _controlChannel;
  MediaStream?        _localStream;
  CameraService?      _cameraService;

  // RTP senders kept so we can swap tracks via replaceTrack() when the camera
  // rebuilds its stream (resolution change / flip) — without renegotiation and
  // without killing the feed.
  RTCRtpSender?       _videoSender;
  RTCRtpSender?       _audioSender;
  Timer?              _statsTimer;
  int                 _statsTick = 0;
  int                 _lastMicBytes = 0;   // audio bytes sent at the previous mic line (DT-315)
  // «Sonido» auto by WHIP (DT-315): mic level every 2 s (newest last, 20 s) and the track WebRTC processes now.
  final List<double>  _micDb = [];
  bool                _micSwitching = false;
  MediaStreamTrack?   _micTrack;
  Timer?              _heartbeatTimer;

  // Return audio (talkback): the engine sends the program mix back over the
  // SAME audio m-line the phone's mic goes out on (see whip_server.cpp —
  // it forces that section sendrecv and reuses the inbound track to answer
  // on). onTrack below is the only piece that was missing; SRTP, jitter
  // buffer and Opus PLC all come free from libwebrtc once the track exists.
  MediaStreamTrack?   _remoteAudioTrack;
  bool                _talkbackMuted = false;
  bool                get talkbackMuted => _talkbackMuted;

  // Getters
  ConnectionState get state        => _state;
  bool            get isConnected  => _state == ConnectionState.connected;
  String          get engineIp     => _engineIp;
  int             get enginePort   => _enginePort;
  String          get sourceId     => _sourceId;
  String          get sourceName   => _sourceName;
  String          get errorMessage => _errorMessage;
  int             get latencyMs    => _latencyMs;
  bool            get isOnAir      => _isOnAir;

  // ---- Persistence ----
  Future<void> loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    _engineIp   = prefs.getString('engine_ip')   ?? '';
    _enginePort = prefs.getInt('engine_port')     ?? 8080;
    _sourceId   = prefs.getString('source_id')   ?? 'cam1';
    _sourceName = prefs.getString('source_name') ?? 'Mobile Cam';
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('engine_ip',   _engineIp);
    await prefs.setInt('engine_port',    _enginePort);
    await prefs.setString('source_id',   _sourceId);
    await prefs.setString('source_name', _sourceName);
  }

  // ---- Connect ----
  Future<void> connect({
    required String engineIp,
    required int    enginePort,
    required String sourceId,
    required String sourceName,
    required MediaStream stream,
    required CameraService cameraService,
  }) async {
    _engineIp      = engineIp;
    _enginePort    = enginePort;
    _sourceId      = sourceId;
    _sourceName    = sourceName;
    _localStream   = stream;
    _cameraService = cameraService;
    // When the camera rebuilds its stream, swap the new tracks onto our senders.
    _cameraService!.onStreamRebuilt = _onStreamRebuilt;
    _state         = ConnectionState.connecting;
    _errorMessage  = '';
    notifyListeners();

    try {
      await _createPeerConnection(stream);
      await saveSettings();
    } catch (e) {
      _state        = ConnectionState.error;
      _errorMessage = e.toString();
      notifyListeners();
      debugPrint('[SambaAir] Connection failed: $e');
    }
  }

  // ---- Create WebRTC PeerConnection + WHIP signaling ----
  Future<void> _createPeerConnection(MediaStream stream) async {
    final config = <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        {'urls': 'stun:stun.cloudflare.com:3478'},
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(config);

    // Register the ICE-connection handler NOW, before setRemoteDescription kicks
    // off connectivity checks. On a fast LAN, ICE can reach Connected within
    // milliseconds of the answer being applied; if the handler is attached after
    // setRemoteDescription (as it was), that Connected event is missed and the
    // state never advances → stats/heartbeat never start.
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('[SambaAir] ICE: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _state = ConnectionState.connected;
        notifyListeners();
        _startStats();
        _startHeartbeat();
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _state        = ConnectionState.error;
        _errorMessage = 'WebRTC connection lost (ICE $state)';
        notifyListeners();
      }
    };

    // Return audio (talkback) arrives here — the engine answers the audio
    // m-line sendrecv and sends the program mix back on it. Without this
    // handler the track was simply never retained: WHIP talkback compiled
    // and connected but nothing played, because nothing on the Dart side
    // ever looked at the inbound track.
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind != 'audio') return;
      debugPrint('[SambaAir] talkback audio track received');
      _remoteAudioTrack = event.track;
      // enabled=false silences playback without an SDP renegotiation —
      // same mute semantics as the SBL side's talkbackMuted flag.
      _remoteAudioTrack!.enabled = !_talkbackMuted;
    };

    // CRITICAL: use addTrack(), NOT addTransceiver() with sendEncodings.
    //
    // addTransceiver with a sendEncodings list does NOT emit an a=ssrc line for
    // the video m-section in this flutter_webrtc build. Without a=ssrc the
    // engine's libdatachannel silently drops every video RTP packet → ICE
    // connects, the track opens, but no frame ever arrives → black video.
    // (The audio track, added without encodings, kept its ssrc — that mismatch
    // is what pinned the bug.)
    //
    // addTrack always assigns an ssrc and is the path that worked originally.
    // Bitrate is shaped afterwards via setParameters() + SDP x-google-* munging.
    RTCRtpSender? videoSender;
    for (final track in stream.getTracks()) {
      final sender = await _peerConnection!.addTrack(track, stream);
      if (track.kind == 'video') {
        videoSender   = sender;
        _videoSender  = sender;   // kept for replaceTrack() on rebuild
      } else if (track.kind == 'audio') {
        _audioSender  = sender;
      }
    }

    // Shape the video encoding AFTER the sender exists (this keeps the ssrc
    // that addTrack assigned, unlike sendEncodings in addTransceiver).
    if (videoSender != null) {
      try {
        final params = videoSender.parameters;
        if (params.encodings != null && params.encodings!.isNotEmpty) {
          for (final enc in params.encodings!) {
            enc.minBitrate            = 3000000;  // 3 Mbps floor (LAN)
            enc.maxBitrate            = 12000000; // 12 Mbps cap (was 6: low once 1080p/4K really arrive)
            enc.maxFramerate          = 60;
            enc.scaleResolutionDownBy = 1.0;       // never downscale
          }
          await videoSender.setParameters(params);
        }
      } catch (e) {
        debugPrint('[SambaAir] setParameters failed (non-fatal): $e');
      }
    }

    // Control data channel — phone creates as offerer so it appears in the
    // SDP offer. The engine receives it via onDataChannel and stores it to
    // send resolution/on-air commands.
    _controlChannel = await _peerConnection!.createDataChannel(
      'vortex-control',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = 5,
    );
    _controlChannel!.onMessage = (msg) {
      if (msg.text != null) _handleEngineMessage(msg.text!);
    };
    _controlChannel!.onDataChannelState = (state) {
      debugPrint('[SambaAir] control channel: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _sendCapabilities();
      }
    };

    // Create SDP offer. Do NOT pass offerToReceive* — those are legacy Plan-B
    // options that, under unified-plan, can override the transceiver directions
    // and force recvonly. The SendOnly transceivers above already define intent.
    final offer  = await _peerConnection!.createOffer();
    final munged = _forceSendOnly(_mungeH264Bitrate(_preferH264(offer.sdp ?? '')));
    await _peerConnection!.setLocalDescription(RTCSessionDescription(munged, 'offer'));

    // Wait for ICE gathering (with 5-second timeout)
    await _waitForIceGathering();

    final localDesc = await _peerConnection!.getLocalDescription();
    if (localDesc == null) throw Exception('Failed to get local SDP');

    // CRITICAL: getLocalDescription() returns WebRTC's regenerated SDP, which
    // can revert our a=sendonly back to a=recvonly. Re-apply _forceSendOnly to
    // the bytes we actually POST so the engine sees sendonly and forwards RTP.
    final offerToSend = _forceSendOnly(localDesc.sdp ?? '');
    debugPrint('[SambaAir] offer POSTed:\n$offerToSend');

    // WHIP POST — send offer to VortexEngine
    // Timeout is 30 s: DTLS cert generation on first run can take up to 8 s,
    // plus ICE gathering (1-3 s) and Vulkan pipeline init (1-2 s).
    final url = Uri.parse('http://$_engineIp:$_enginePort/whip/$_sourceId');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/sdp',
        'X-Source-Name': Uri.encodeComponent(_sourceName),
      },
      body: offerToSend,
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception('WHIP rejected: HTTP ${response.statusCode} — ${response.body}');
    }
    final loc = response.headers['location'];
    _whipResourceUrl = (loc != null && loc.isNotEmpty) ? url.resolve(loc).toString() : null;

    // Apply SDP answer (the onIceConnectionState handler was already registered
    // right after createPeerConnection, so a fast LAN connection is not missed).
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(response.body, 'answer'),
    );

    debugPrint('[SambaAir] WHIP handshake complete → waiting for ICE...');
  }

  Future<void> _waitForIceGathering() async {
    if (_peerConnection!.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    final completer = Completer<void>();
    final timeout   = Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) completer.complete();
    });
    _peerConnection!.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        timeout.cancel();
        if (!completer.isCompleted) completer.complete();
      }
    };
    await completer.future;
  }

  // ---- Announce capabilities to the engine's resolution "director" ----
  // replaceTrackSafe=true tells the engine this app can change capture
  // resolution without freezing (it swaps tracks via replaceTrack). Without
  // this flag the engine never commands a resolution change. maxWidth/Height is
  // the ceiling the engine may aim for.
  void _sendCapabilities() {
    final dc = _controlChannel;
    if (dc == null) return;
    final msg = jsonEncode({
      'type':            'capabilities',
      'replaceTrackSafe': true,
      'maxWidth':         3840,   // aim for 4K; engine director falls back if unsustainable
      'maxHeight':        2160,
    });
    try {
      dc.send(RTCDataChannelMessage(msg));
      debugPrint('[SambaAir] capabilities sent → $msg');
    } catch (e) {
      debugPrint('[SambaAir] capabilities send failed: $e');
    }
  }

  // ---- Camera stream rebuilt → swap tracks onto live senders ----
  // Called by CameraService after a resolution change or camera flip. We swap
  // the freshly-captured tracks onto the existing RTP senders via replaceTrack()
  // so media keeps flowing without an SDP renegotiation. The previous behaviour
  // (rebuild without replaceTrack) left the senders pointing at stopped tracks →
  // frozen phone + black video on the engine.
  Future<void> _onStreamRebuilt(MediaStream stream) async {
    try {
      final v = stream.getVideoTracks().firstOrNull;
      final a = stream.getAudioTracks().firstOrNull;
      if (v != null && _videoSender != null) await _videoSender!.replaceTrack(v);
      if (a != null && _audioSender != null) {
        await _audioSender!.replaceTrack(a);
        try { await _micTrack?.stop(); } catch (_) {}   // the «Sonido» auto track, if one was swapped in
        _micTrack = null;
      }
      _localStream = stream;
      debugPrint('[SambaAir] stream rebuilt → tracks replaced on senders');
    } catch (e) {
      debugPrint('[SambaAir] replaceTrack on rebuild failed: $e');
    }
  }

  // ---- Engine → Phone control messages (via data channel) ----
  void _handleEngineMessage(String json) {
    try {
      final msg = jsonDecode(json) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'set_resolution':
          final w = (msg['width']  as num?)?.toInt() ?? 1280;
          final h = (msg['height'] as num?)?.toInt() ?? 720;
          debugPrint('[SambaAir] engine → set_resolution ${w}x$h');
          _cameraService?.applyResolutionFromEngine(w, h);
          break;

        case 'on_air':
          _isOnAir = msg['active'] as bool? ?? false;
          notifyListeners();
          break;

        case 'pong':
          final sentMs = msg['sentMs'] as int? ?? 0;
          _latencyMs = DateTime.now().millisecondsSinceEpoch - sentMs;
          notifyListeners();
          break;
      }
    } catch (_) {}
  }

  // ---- Stats polling ----
  void _startStats() {
    // ICE reports Connected AND then Completed: both call here. A second timer doubled _statsTick, so the
    // "no video after 12 s" check below fired at ~6 s — before a 4K portrait encoder had sent its first frame
    // (8 s on the Redmi Note 14, 2026-10-15) — and greyed WHIP for good on a phone that streams fine.
    if (_statsTimer?.isActive ?? false) return;
    _statsTick = 0;
    _lastMicBytes = 0;
    _micDb.clear();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_peerConnection == null) return;
      final stats = await _peerConnection!.getStats();
      // Microphone, measured (DT-315): by WHIP the engine decoded silence. The level WebRTC sees at the source and
      // the audio bytes that went out, on the same line as the video every 6 s.
      double? micLevel, retLevel; int? micBytes;
      for (final report in stats) {
        final v = report.values;
        if (report.type == 'media-source' && v['kind'] == 'audio') micLevel = (v['audioLevel'] as num?)?.toDouble();
        if (report.type == 'inbound-rtp' && (v['mediaType'] == 'audio' || v['kind'] == 'audio')) {
          retLevel = (v['audioLevel'] as num?)?.toDouble();   // the return (talkback), as it plays
        }
        if (report.type == 'outbound-rtp' && (v['mediaType'] == 'audio' || v['kind'] == 'audio')) {
          micBytes = (v['bytesSent'] as num?)?.toInt();
        }
      }
      if (micLevel != null) _noteMicForAuto(micLevel);
      for (final report in stats) {
        final v = report.values;
        if (report.type == 'outbound-rtp' && (v['mediaType'] == 'video' || v['kind'] == 'video')) {
          // What the encoder actually sends and why it would send less (cpu / bandwidth / none).
          _statsTick++;
          // Live safety net for the capability probe: connected for 12 s and (almost) no video BYTES sent = this
          // phone's encoder can't run inside WebRTC. Bytes, not framesEncoded: early stats can come without that
          // field (null), which read as 0 wrongly greyed WHIP on a Mi A3 that can do it (2026-10-04).
          // Window is 20 s, not 12: a 4K encoder can take 8 s to start. Once video has flowed, the phone is
          // remembered as WHIP-capable and never greyed by a later slow start or a stall.
          final sentBytes = (v['bytesSent'] as num?)?.toInt();
          if (sentBytes != null && sentBytes >= 20000) {
            DeviceCapabilities.instance.markWhipSupported();
          } else if (_statsTick == 10 && sentBytes != null && !DeviceCapabilities.instance.whipKnownGood) {
            const why = 'el encoder H.264 no arrancó al transmitir';
            DeviceCapabilities.instance.markWhipUnsupported(why);
            _state        = ConnectionState.error;
            _errorMessage = 'Este celular no puede WHIP ($why). Usá SBL o SRT.';
            notifyListeners();
          }
          if (_statsTick % 3 == 0) {
            debugPrint('[SambaAir] WHIP envío: ${v['frameWidth']}x${v['frameHeight']} '
                '${v['framesPerSecond']} fps · objetivo ${((v['targetBitrate'] as num?) ?? 0) ~/ 1000} kbps · '
                'límite=${v['qualityLimitationReason']} · encoder=${v['encoderImplementation']}');
            String dbOf(double? l) => l == null ? 'sin dato' : l <= 0 ? 'silencio' :
                '${(20 * math.log(l) / math.ln10).toStringAsFixed(0)} dBFS';
            final kbps = micBytes == null ? '?' : (((micBytes - _lastMicBytes) * 8) / 6000).toStringAsFixed(1);
            if (micBytes != null) _lastMicBytes = micBytes;
            final mode = SambaMic.mode == SambaMicMode.auto
                ? 'auto: ${SambaMic.autoVoice ? 'voz' : 'natural'}' : SambaMic.mode.name;
            debugPrint('[SambaAir] WHIP mic: nivel ${dbOf(micLevel)} · audio enviado $kbps kbps · sonido $mode · '
                'retorno ${dbOf(retLevel)}');
          }
          break;
        }
      }
    });
  }

  // ---- «Sonido» auto by WHIP (DT-315) ----
  // The same rule as MicProcessing.kt on SRT/SBL, on WebRTC's mic level sampled every 2 s: voice after 10 s whose
  // quietest sample is above −50 dBFS (steady background noise: speech has pauses), natural again after 20 s whose two
  // halves both have a sample under −66 (lower: with voice on, what is measured is already partly cleaned).
  void _noteMicForAuto(double level) {
    if (SambaMic.mode != SambaMicMode.auto) { _micDb.clear(); return; }
    _micDb.add(level <= 0 ? -120 : 20 * math.log(level) / math.ln10);
    while (_micDb.length > 10) { _micDb.removeAt(0); }
    double minOf(Iterable<double> l) => l.reduce(math.min);
    if (!SambaMic.autoVoice && _micDb.length >= 5) {
      final floor = minOf(_micDb.skip(_micDb.length - 5));
      if (floor > -50) _switchMicProcessing(true, 'voz por ruido de fondo (piso ${floor.toStringAsFixed(0)} dBFS durante 10 s)');
    } else if (SambaMic.autoVoice && _micDb.length >= 10) {
      final floor = math.max(minOf(_micDb.take(5)), minOf(_micDb.skip(5)));
      if (floor < -66) _switchMicProcessing(false, 'natural, se calmó (piso ${floor.toStringAsFixed(0)} dBFS durante 20 s)');
    }
  }

  // WebRTC's processing is chosen when the mic track is opened: a new audio-only track with the other constraints,
  // swapped onto the live sender (replaceTrack, no renegotiation). The video is untouched.
  Future<void> _switchMicProcessing(bool voice, String why) async {
    if (_micSwitching || _audioSender == null) return;
    _micSwitching = true;
    try {
      final s = await navigator.mediaDevices.getUserMedia({'audio': SambaMic.constraints(voice: voice), 'video': false});
      final t = s.getAudioTracks().firstOrNull;
      if (t == null) return;
      await _audioSender!.replaceTrack(t);
      final old = _micTrack ?? _localStream?.getAudioTracks().firstOrNull;
      _micTrack = t;
      try { await old?.stop(); } catch (_) {}
      SambaMic.autoVoice = voice;
      _micDb.clear();
      debugPrint('[SambaAir] [mic] modo → $why');
    } catch (e) {
      debugPrint('[SambaAir] [mic] cambio de sonido falló: $e');
    } finally {
      _micSwitching = false;
    }
  }

  // ---- Heartbeat via data channel (latency + keep-alive) ----
  void _startHeartbeat() {
    if (_heartbeatTimer?.isActive ?? false) return;   // Connected + Completed both land here (see _startStats)
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!isConnected) return;
      final dc = _controlChannel;
      if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        // Ping via data channel — engine echoes back {"type":"pong","sentMs":T}
        final ping = jsonEncode({
          'type':   'ping',
          'sentMs': DateTime.now().millisecondsSinceEpoch,
        });
        try { dc.send(RTCDataChannelMessage(ping)); } catch (_) {}
      } else {
        // Fallback: HTTP ping if data channel not open yet
        _httpPing();
      }
    });
  }

  Future<void> _httpPing() async {
    try {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      final r  = await http.get(
        Uri.parse('http://$_engineIp:$_enginePort/status'),
      ).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        _latencyMs = DateTime.now().millisecondsSinceEpoch - t0;
        try {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          _isOnAir = body['active_source'] == _sourceId;
        } catch (_) {}
        notifyListeners();
      }
    } catch (_) {}
  }

  // ---- Talkback mute toggle (WHIP path) ----
  // Called from the UI's single talkback button — VortexCamPlugin handles the
  // SBL side via the "setTalkbackMuted" MethodChannel call; this is the WHIP
  // counterpart, entirely local (no renegotiation, no native call).
  void setTalkbackMuted(bool muted) {
    _talkbackMuted = muted;
    _remoteAudioTrack?.enabled = !muted;
  }

  // ---- Disconnect ----
  Future<void> disconnect() async {
    _statsTimer?.cancel();
    _heartbeatTimer?.cancel();
    _statsTimer     = null;
    _heartbeatTimer = null;

    _controlChannel?.close();
    _controlChannel = null;

    await _peerConnection?.close();
    _peerConnection = null;
    _localStream    = null;
    try { await _micTrack?.stop(); } catch (_) {}
    _micTrack = null;
    SambaMic.autoVoice = false;
    _videoSender    = null;
    _audioSender    = null;
    _remoteAudioTrack = null;
    _cameraService?.onStreamRebuilt = null;   // detach callback to avoid stale refs
    _cameraService  = null;
    _state          = ConnectionState.disconnected;
    _isOnAir        = false;
    notifyListeners();

    // WHIP DELETE to notify engine
    try {
      await http.delete(
        Uri.parse(_whipResourceUrl ?? 'http://$_engineIp:$_enginePort/whip/$_sourceId'),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}
    _whipResourceUrl = null;

    debugPrint('[SambaAir] Disconnected from engine.');
  }

  // Inject x-google-{min,max,start}-bitrate into every H264 a=fmtp line.
  // These SDP attributes inform Android's GCC (congestion controller):
  //   min=1500  kbps — floor prevents the 320×192 startup ramp from dragging on
  //   max=6000  kbps — cap below REMB target (5 Mbps) so GCC converges fast
  //   start=3000 kbps — opener estimate; GCC ramps up instead of down from here
  String _mungeH264Bitrate(String sdp) {
    return sdp.replaceAllMapped(
      RegExp(r'(a=fmtp:\d+ [^\r\n]*packetization-mode[^\r\n]*)'),
      (m) {
        final line = m.group(1)!;
        if (line.contains('x-google-min-bitrate')) return line;
        // LAN to SAMBA: start high so the encoder's first frames are not judged against a low estimate and scaled
        // down (WHIP arrived at 720p with a 1080p capture, 2026-10-04).
        return '$line;x-google-min-bitrate=3000;x-google-max-bitrate=12000;x-google-start-bitrate=6000';
      },
    );
  }

  // Keep only H.264 (and its RTX) payload types in the video m-line.
  String _preferH264(String sdp) {
    final lines  = sdp.split(RegExp(r'\r\n|\n'));
    final mIdx   = lines.indexWhere((l) => l.startsWith('m=video'));
    if (mIdx < 0) return sdp;

    final rtpmap     = <String, String>{};
    final apt        = <String, String>{};
    final reFmtpApt  = RegExp(r'a=fmtp:(\d+).*apt=(\d+)');
    final reRtpmap   = RegExp(r'a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/');
    for (final l in lines) {
      final m = reRtpmap.firstMatch(l);
      if (m != null) rtpmap[m.group(1)!] = m.group(2)!.toUpperCase();
      final a = reFmtpApt.firstMatch(l);
      if (a != null) apt[a.group(1)!] = a.group(2)!;
    }

    final keep = <String>{};
    rtpmap.forEach((pt, name) { if (name == 'H264') keep.add(pt); });
    if (keep.isEmpty) return sdp;
    apt.forEach((rtxPt, refPt) { if (keep.contains(refPt)) keep.add(rtxPt); });

    final parts  = lines[mIdx].split(' ');
    final header = parts.sublist(0, 3);
    final kept   = parts.sublist(3).where(keep.contains).toList();
    lines[mIdx]  = ([...header, ...kept]).join(' ');

    // BUG (found 2026-08-10): this filter used to run over the WHOLE sdp
    // without tracking which m-section it was in. `keep` only ever contains
    // video H264 payload types, so it silently deleted the audio codec's own
    // a=rtpmap/fmtp/rtcp-fb lines too (any PT not in the video-only `keep`
    // set got dropped, audio included) — the offer left the phone with a
    // real Opus track, but by the time SAMBA parsed it there was no rtpmap
    // for it left: "Opus_PT=-1", audio silently missing end-to-end. Scope
    // the removal to the video m-section only.
    final rePt = RegExp(r'a=(rtpmap|fmtp|rtcp-fb):(\d+)');
    final out  = <String>[];
    bool inVideo = false;
    for (final l in lines) {
      if (l.startsWith('m=')) {
        inVideo = l.startsWith('m=video');
        out.add(l);
        continue;
      }
      if (inVideo) {
        final m = rePt.firstMatch(l);
        if (m != null && !keep.contains(m.group(2))) continue;
      }
      out.add(l);
    }
    return out.join('\r\n');
  }

  // Force the video m-section to advertise a=sendonly.
  // Walks the SDP line by line: once inside the m=video block, any
  // a=sendrecv / a=recvonly / a=inactive line becomes a=sendonly.
  // The audio/application sections are left untouched.
  String _forceSendOnly(String sdp) {
    final lines = sdp.split(RegExp(r'\r\n|\n'));
    bool inVideo = false;
    for (int i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l.startsWith('m=')) {
        inVideo = l.startsWith('m=video');
        continue;
      }
      if (inVideo) {
        if (l == 'a=sendrecv' || l == 'a=recvonly' || l == 'a=inactive') {
          lines[i] = 'a=sendonly';
        }
      }
    }
    return lines.join('\r\n');
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
