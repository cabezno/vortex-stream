import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// ConnectionService — manages WebRTC/WHIP connection to VortexEngine
//
// Protocol: WHIP (WebRTC-HTTP Ingest Protocol)
//   POST http://{engine_ip}:8080/whip/{source_id}
//   Body: SDP offer
//   Response: SDP answer
// =============================================================================

enum ConnectionState { disconnected, connecting, connected, error }

class ConnectionService extends ChangeNotifier {
  ConnectionState _state = ConnectionState.disconnected;
  String _engineIp       = '';
  String _sourceId       = 'cam1';
  String _sourceName     = 'Mobile Cam';
  String _errorMessage   = '';
  int    _latencyMs      = 0;
  bool   _isOnAir        = false;   // set by engine when this cam is active

  RTCPeerConnection?  _peerConnection;
  MediaStream?        _localStream;
  Timer?              _statsTimer;
  Timer?              _heartbeatTimer;

  // Getters
  ConnectionState get state        => _state;
  bool            get isConnected  => _state == ConnectionState.connected;
  String          get engineIp     => _engineIp;
  String          get sourceId     => _sourceId;
  String          get sourceName   => _sourceName;
  String          get errorMessage => _errorMessage;
  int             get latencyMs    => _latencyMs;
  bool            get isOnAir      => _isOnAir;

  // ---- Persistence ----
  Future<void> loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    _engineIp   = prefs.getString('engine_ip')   ?? '';
    _sourceId   = prefs.getString('source_id')   ?? 'cam1';
    _sourceName = prefs.getString('source_name') ?? 'Mobile Cam';
    notifyListeners();
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('engine_ip',   _engineIp);
    await prefs.setString('source_id',   _sourceId);
    await prefs.setString('source_name', _sourceName);
  }

  // ---- Connect ----
  Future<void> connect({
    required String engineIp,
    required String sourceId,
    required String sourceName,
    required MediaStream stream,
  }) async {
    _engineIp   = engineIp;
    _sourceId   = sourceId;
    _sourceName = sourceName;
    _localStream = stream;
    _state      = ConnectionState.connecting;
    _errorMessage = '';
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
        // Local LAN — no STUN needed. For internet use, add STUN/TURN.
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };

    _peerConnection = await createPeerConnection(config);

    // Add tracks. For video: use addTransceiver with scaleResolutionDownBy=1.0 so
    // the Android WebRTC quality scaler cannot downgrade resolution when the engine
    // sends no REMB/transport-cc feedback (without feedback BWE stays at minimum,
    // causing the encoder to emit 320×192 indefinitely).
    for (final track in stream.getTracks()) {
      if (track.kind == 'video') {
        await _peerConnection!.addTransceiver(
          track: track,
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly,
            sendEncodings: [
              RTCRtpEncoding(
                maxBitrate: 4000000,       // 4 Mbps — enough headroom for 1080p
                maxFramerate: 60,
                scaleResolutionDownBy: 1.0, // never downscale
              ),
            ],
          ),
        );
      } else {
        await _peerConnection!.addTrack(track, stream);
      }
    }

    // Create SDP offer
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': false,
      'offerToReceiveVideo': false,
    });
    await _peerConnection!.setLocalDescription(offer);

    // Wait for ICE gathering (with timeout)
    await _waitForIceGathering();

    final localDesc = await _peerConnection!.getLocalDescription();
    if (localDesc == null) throw Exception('Failed to get local SDP');

    // WHIP POST — send offer to VortexEngine
    final url = Uri.parse('http://$_engineIp:8080/whip/$_sourceId');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/sdp',
        'X-Source-Name': Uri.encodeComponent(_sourceName),
      },
      body: localDesc.sdp,
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode != 201 && response.statusCode != 200) {
      throw Exception('WHIP rejected: HTTP ${response.statusCode} — ${response.body}');
    }

    // Parse SDP answer
    final answerSdp = response.body;
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(answerSdp, 'answer'),
    );

    // ICE connection state monitoring
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
        _state = ConnectionState.error;
        _errorMessage = 'WebRTC connection lost (ICE $state)';
        notifyListeners();
      }
    };

    // Data channel for bidirectional control (engine → phone: "you're live!")
    _peerConnection!.onDataChannel = (channel) {
      channel.onMessage = (msg) => _handleEngineMessage(msg.text);
    };

    debugPrint('[VortexCam] WHIP handshake complete → waiting for ICE...');
  }

  Future<void> _waitForIceGathering() async {
    final completer = Completer<void>();
    Timer timeout = Timer(const Duration(seconds: 5), () {
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

  // ---- Engine → Phone messages (data channel) ----
  void _handleEngineMessage(String json) {
    try {
      final msg = jsonDecode(json) as Map<String, dynamic>;
      switch (msg['type']) {
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
          // Could extract bitrate, FPS, packets sent here
          break;
        }
      }
    });
  }

  // ---- Heartbeat (keep-alive + latency measurement) ----
  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!isConnected) return;
      // Simple HTTP ping to engine status endpoint
      try {
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final r = await http.get(
          Uri.parse('http://$_engineIp:8080/status'),
        ).timeout(const Duration(seconds: 3));
        if (r.statusCode == 200) {
          _latencyMs = DateTime.now().millisecondsSinceEpoch - t0;
          // Check if we're on air
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          _isOnAir = body['active_source'] == _sourceId;
          notifyListeners();
        }
      } catch (_) { /* ignore — connection handles its own state */ }
    });
  }

  // ---- Disconnect ----
  Future<void> disconnect() async {
    _statsTimer?.cancel();
    _heartbeatTimer?.cancel();
    _statsTimer = null;
    _heartbeatTimer = null;

    await _peerConnection?.close();
    _peerConnection = null;
    _localStream    = null;
    _state          = ConnectionState.disconnected;
    _isOnAir        = false;
    notifyListeners();

    // WHIP DELETE to notify engine
    try {
      await http.delete(
        Uri.parse('http://$_engineIp:8080/whip/$_sourceId'),
      ).timeout(const Duration(seconds: 3));
    } catch (_) {}

    debugPrint('[VortexCam] Disconnected from engine.');
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
