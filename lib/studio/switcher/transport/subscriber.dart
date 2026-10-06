import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:samba_protocol/samba_protocol.dart';
import '../room/room_host.dart';

/// WebRTC Subscriber manager for the Switcher.
/// Accepts incoming WebRTC streams from connected cameras,
/// manages local RTCVideoRenderers for multiview miniaturas,
/// and feeds the active stream to the Program monitor.
class WebRtcSubscriber extends ChangeNotifier {
  final RoomHost roomHost;

  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, MediaStream> _remoteStreams = {};
  final Map<String, RTCVideoRenderer> _renderers = {};
  String? _activeAudioPeerId;

  WebRtcSubscriber({required this.roomHost}) {
    _setupRoomListeners();
  }

  /// What actually arrives from each camera, measured every 3 s: the multiview shows it so PGM/PVW (and 4K on air)
  /// can be checked at a glance — e.g. "1080p · 30" for the on-air one, "360p · 15" for the others.
  final Map<String, ({int height, int fps})> received = {};

  Map<String, RTCVideoRenderer> get renderers => _renderers;
  Map<String, MediaStream> get remoteStreams => _remoteStreams;
  String? get activeAudioPeerId => _activeAudioPeerId;

  /// Ensures ONLY the active on-air camera has its audio track enabled,
  /// preventing all remote microphones from sounding at the same time.
  void updateActiveAudioTrack(String? activePeerId) {
    _activeAudioPeerId = activePeerId;
    for (final entry in _remoteStreams.entries) {
      final peerId = entry.key;
      final stream = entry.value;
      final isPeerActive = (peerId == activePeerId);
      for (final audioTrack in stream.getAudioTracks()) {
        audioTrack.enabled = isPeerActive;
      }
    }
    notifyListeners();
  }

  void _setupRoomListeners() {
    roomHost.onWebRtcOffer = _handleOffer;
    roomHost.onWebRtcCandidate = _handleCandidate;
    roomHost.onPeerLeft = _handlePeerLeft;
  }

  /// Returns the video renderer for a given camera peer
  RTCVideoRenderer? getRenderer(String peerId) => _renderers[peerId];

  /// Handles incoming SDP Offer from a camera
  Future<void> _handleOffer(OfferMessage offer) async {
    final peerId = offer.from;
    debugPrint('[WebRtcSubscriber] Received offer from $peerId');

    // Clean up any existing connection for this peer
    await _closePeer(peerId);

    final rtcConfig = <String, dynamic>{
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };

    final pc = await createPeerConnection(rtcConfig);
    _peerConnections[peerId] = pc;

    pc.onConnectionState = (s) => debugPrint('[WebRtcSubscriber] connState=$s for $peerId');
    pc.onIceConnectionState = (s) => debugPrint('[WebRtcSubscriber] iceState=$s for $peerId');
    pc.onIceGatheringState = (s) => debugPrint('[WebRtcSubscriber] iceGathering=$s for $peerId');

    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    _renderers[peerId] = renderer;

    pc.onIceCandidate = (candidate) {
      roomHost.sendToPeer(
        peerId,
        IceCandidateMessage(
          from: 'switcher',
          to: peerId,
          candidate: {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        ),
      );
    };

    pc.onTrack = (RTCTrackEvent event) async {
      // Robusto: si el track llega SIN stream (típico del video por addTransceiver
      // con simulcast), igual lo montamos en un stream propio para poder renderizarlo.
      MediaStream stream;
      if (event.streams.isNotEmpty) {
        stream = event.streams.first;
      } else {
        stream = _remoteStreams[peerId] ??
            await createLocalMediaStream('remote_$peerId');
        await stream.addTrack(event.track);
      }
      _remoteStreams[peerId] = stream;

      if (event.track.kind == 'video') {
        // Bind EXPLÍCITO por trackId. El setter `renderer.srcObject = stream`
        // solo pasa streamId (sin trackId) y NO enganchaba el sink del renderer
        // al track de video remoto → el EglRenderer de pantalla recibía 0 frames
        // (negro) y el decoder VP8 se trababa por backpressure de buffers.
        // setSrcObject(trackId:) ata el renderer al track exacto.
        await renderer.setSrcObject(stream: stream, trackId: event.track.id);
      } else if (event.track.kind == 'audio') {
        // Mute incoming audio if not currently the active speaker
        event.track.enabled = (peerId == _activeAudioPeerId);
      }

      debugPrint('[WebRtcSubscriber] Received track (${event.track.kind}, streams=${event.streams.length}) for $peerId');
      notifyListeners();
    };

    // Set Remote Description (the Camera's Offer)
    await pc.setRemoteDescription(RTCSessionDescription(offer.sdp, 'offer'));

    // Create SDP Answer (sin constraints legacy; unified-plan responde recvonly
    // automáticamente al offer sendonly de la cámara).
    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);

    // Send Answer back to Camera
    roomHost.sendToPeer(
      peerId,
      AnswerMessage(
        from: 'switcher',
        to: peerId,
        sdp: answer.sdp ?? '',
      ),
    );

    // DIAGNÓSTICO: log de stats de recepción de video cada 3s
    Timer.periodic(const Duration(seconds: 3), (t) async {
      final p = _peerConnections[peerId];
      if (p == null) {
        t.cancel();
        return;
      }
      try {
        final reports = await p.getStats();
        for (final r in reports) {
          final v = r.values;
          if (r.type == 'inbound-rtp' &&
              (v['mediaType'] == 'video' || v['kind'] == 'video')) {
            debugPrint(
                '[Subscriber STATS] $peerId framesReceived=${v['framesReceived']} framesDecoded=${v['framesDecoded']} '
                'framesDropped=${v['framesDropped']} bytesReceived=${v['bytesReceived']} packetsReceived=${v['packetsReceived']} '
                'packetsLost=${v['packetsLost']} nack=${v['nackCount']} pli=${v['pliCount']} freezes=${v['freezeCount']} '
                'jitter=${v['jitter']} fps=${v['framesPerSecond']} ${v['frameWidth']}x${v['frameHeight']}');
            final w = (v['frameWidth'] as num?)?.toInt() ?? 0, h = (v['frameHeight'] as num?)?.toInt() ?? 0;
            final now = (height: w < h ? w : h, fps: ((v['framesPerSecond'] as num?) ?? 0).round());
            if (received[peerId] != now) {
              received[peerId] = now;
              notifyListeners();
            }
          }
        }
      } catch (_) {}
    });

    notifyListeners();
  }

  /// Handles incoming remote ICE candidates
  Future<void> _handleCandidate(IceCandidateMessage msg) async {
    final pc = _peerConnections[msg.from];
    debugPrint('[WebRtcSubscriber] remote candidate from ${msg.from} (pc=${pc != null})');
    if (pc != null) {
      final candMap = msg.candidate;
      final cand = RTCIceCandidate(
        candMap['candidate'] as String?,
        candMap['sdpMid'] as String?,
        candMap['sdpMLineIndex'] as int?,
      );
      await pc.addCandidate(cand);
    }
  }

  void _handlePeerLeft(String peerId) {
    _closePeer(peerId);
  }

  Future<void> _closePeer(String peerId) async {
    final pc = _peerConnections.remove(peerId);
    await pc?.close();

    final renderer = _renderers.remove(peerId);
    renderer?.srcObject = null;
    await renderer?.dispose();

    _remoteStreams.remove(peerId);
    received.remove(peerId);
    notifyListeners();
  }

  /// Dispose all peer connections and video renderers
  Future<void> disposeAll() async {
    for (final pc in _peerConnections.values) {
      await pc.close();
    }
    _peerConnections.clear();

    for (final r in _renderers.values) {
      r.srcObject = null;
      await r.dispose();
    }
    _renderers.clear();
    _remoteStreams.clear();
  }

  @override
  void dispose() {
    disposeAll();
    super.dispose();
  }
}
