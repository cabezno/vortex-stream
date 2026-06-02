import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'camera_service.dart';

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
  String _sourceName            = 'Mobile Cam';
  String _errorMessage          = '';
  int    _latencyMs             = 0;
  bool   _isOnAir               = false;

  RTCPeerConnection?  _peerConnection;
  RTCDataChannel?     _controlChannel;
  MediaStream?        _localStream;
  CameraService?      _cameraService;
  Timer?              _statsTimer;
  Timer?              _heartbeatTimer;

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
      debugPrint('[VortexCam] Connection failed: $e');
    }
  }

  // ---- Create WebRTC PeerConnection + WHIP signaling ----
  Future<void> _createPeerConnection(MediaStream stream) async {
    final config = <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(config);

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
      if (track.kind == 'video') videoSender = sender;
    }

    // Shape the video encoding AFTER the sender exists (this keeps the ssrc
    // that addTrack assigned, unlike sendEncodings in addTransceiver).
    if (videoSender != null) {
      try {
        final params = videoSender.parameters;
        if (params.encodings != null && params.encodings!.isNotEmpty) {
          for (final enc in params.encodings!) {
            enc.minBitrate            = 1500000;  // 1.5 Mbps floor
            enc.maxBitrate            = 6000000;  // 6 Mbps cap
            enc.maxFramerate          = 60;
            enc.scaleResolutionDownBy = 1.0;       // never downscale
          }
          await videoSender.setParameters(params);
        }
      } catch (e) {
        debugPrint('[VortexCam] setParameters failed (non-fatal): $e');
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
      debugPrint('[VortexCam] control channel: $state');
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
    debugPrint('[VortexCam] offer POSTed:\n$offerToSend');

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

    // Apply SDP answer
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(response.body, 'answer'),
    );

    // ICE connection state → update UI
    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('[VortexCam] ICE: $state');
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

    debugPrint('[VortexCam] WHIP handshake complete → waiting for ICE...');
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

  // ---- Engine → Phone control messages (via data channel) ----
  void _handleEngineMessage(String json) {
    try {
      final msg = jsonDecode(json) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'set_resolution':
          final w = (msg['width']  as num?)?.toInt() ?? 1280;
          final h = (msg['height'] as num?)?.toInt() ?? 720;
          debugPrint('[VortexCam] engine → set_resolution ${w}x$h');
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
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_peerConnection == null) return;
      final stats = await _peerConnection!.getStats();
      for (final report in stats) {
        if (report.type == 'outbound-rtp' && report.values['mediaType'] == 'video') {
          break;
        }
      }
    });
  }

  // ---- Heartbeat via data channel (latency + keep-alive) ----
  void _startHeartbeat() {
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
    _cameraService  = null;
    _state          = ConnectionState.disconnected;
    _isOnAir        = false;
    notifyListeners();

    // WHIP DELETE to notify engine
    try {
      await http.delete(
        Uri.parse('http://$_engineIp:$_enginePort/whip/$_sourceId'),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}

    debugPrint('[VortexCam] Disconnected from engine.');
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
        return '$line;x-google-min-bitrate=1500;x-google-max-bitrate=6000;x-google-start-bitrate=3000';
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

    final rePt = RegExp(r'a=(rtpmap|fmtp|rtcp-fb):(\d+)');
    final out  = <String>[];
    for (final l in lines) {
      final m = rePt.firstMatch(l);
      if (m != null && !keep.contains(m.group(2))) continue;
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
