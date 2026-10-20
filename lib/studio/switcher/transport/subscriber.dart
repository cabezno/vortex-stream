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

  /// A camera's ICE candidates that arrived before its offer was applied. A camera sends its offer and, right
  /// behind it, a burst of candidates; they used to arrive while the switcher was still closing the old connection
  /// or creating the new one (pc=false) and were dropped - with two cameras joining at once the camera's own
  /// addresses were all lost and the connection never formed (camera «connected» with 0 bytes sent, black tile,
  /// 2026-10-20). Held here and added once the offer is set.
  final Map<String, List<RTCIceCandidate>> _earlyCandidates = {};

  WebRtcSubscriber({required this.roomHost}) {
    _setupRoomListeners();
  }

  /// What actually arrives from each camera, measured every 3 s: the multiview shows it so PGM/PVW (and 4K on air)
  /// can be checked at a glance — e.g. "1080p · 30" for the on-air one, "360p · 15" for the others.
  final Map<String, ({int height, int fps})> received = {};

  /// Estimated latency of each camera, from WebRTC's own numbers (every 3 s): half the round trip + the playout
  /// (jitter) buffer + decoding. It does not see the camera's capture/encoding, so it reads LOWER than the beep
  /// measurement (SourceSync), which is the one used once taken.
  final Map<String, int> latencyEstMs = {};

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
    // From here until the offer is applied, this camera's candidates wait (see [_earlyCandidates]).
    _earlyCandidates.putIfAbsent(peerId, () => []);

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

    // A camera's tracks are wired up (renderer, enabled, stream) only once its offer is applied. While the offer is
    // being applied WebRTC announces each track from its signaling thread (flutter_webrtc's onAddTrack walks the
    // connection's transceivers there), and wiring the first track right away made flutter_webrtc walk the same
    // transceivers from the main thread (getTrackForId when the track is not registered yet): one disposed what the
    // other was disposing — «RtpTransceiver has been disposed» in a JNI callback, SIGABRT of the whole switcher when a
    // camera joined (2026-10-20).
    final pendingTracks = <RTCTrackEvent>[];
    var negotiating = true;
    Future<void> handleTrack(RTCTrackEvent event) async {
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
    }
    pc.onTrack = (RTCTrackEvent event) {
      if (negotiating) { pendingTracks.add(event); } else { handleTrack(event); }
    };

    // Set Remote Description (the Camera's Offer)
    await pc.setRemoteDescription(RTCSessionDescription(offer.sdp, 'offer'));
    final early = _earlyCandidates.remove(peerId) ?? const <RTCIceCandidate>[];
    for (final c in early) {
      try { await pc.addCandidate(c); } catch (e) { debugPrint('[WebRtcSubscriber] candidate from $peerId: $e'); }
    }
    if (early.isNotEmpty) debugPrint('[WebRtcSubscriber] ${early.length} early candidates from $peerId added');

    // Create SDP Answer (sin constraints legacy; unified-plan responde recvonly
    // automáticamente al offer sendonly de la cámara).
    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);

    // The answer goes out at once, ahead of this switcher's own candidates (gathering starts with
    // setLocalDescription): wiring the tracks first let the candidates reach the camera before its answer.
    roomHost.sendToPeer(
      peerId,
      AnswerMessage(
        from: 'switcher',
        to: peerId,
        sdp: answer.sdp ?? '',
      ),
    );

    negotiating = false;
    for (final e in pendingTracks) {
      await handleTrack(e);
    }
    pendingTracks.clear();

    // DIAGNÓSTICO: log de stats de recepción de video cada 3s
    Timer.periodic(const Duration(seconds: 3), (t) async {
      final p = _peerConnections[peerId];
      if (p == null) {
        t.cancel();
        return;
      }
      try {
        final reports = await p.getStats();
        double rttS = 0, jbS = 0, decS = 0, audioJbS = 0;
        var hasVideo = false;
        for (final r in reports) {
          final v = r.values;
          if (r.type == 'candidate-pair' && v['nominated'] == true && v['currentRoundTripTime'] is num) {
            rttS = (v['currentRoundTripTime'] as num).toDouble();
          }
          if (r.type == 'inbound-rtp' && (v['mediaType'] == 'audio' || v['kind'] == 'audio')) {
            final em = (v['jitterBufferEmittedCount'] as num?)?.toDouble() ?? 0;
            if (em > 0) audioJbS = ((v['jitterBufferDelay'] as num?)?.toDouble() ?? 0) / em;
          }
          if (r.type == 'inbound-rtp' && (v['mediaType'] == 'video' || v['kind'] == 'video')) {
            hasVideo = true;
            final em = (v['jitterBufferEmittedCount'] as num?)?.toDouble() ?? 0;
            if (em > 0) jbS = ((v['jitterBufferDelay'] as num?)?.toDouble() ?? 0) / em;
            final fd = (v['framesDecoded'] as num?)?.toDouble() ?? 0;
            if (fd > 0) decS = ((v['totalDecodeTime'] as num?)?.toDouble() ?? 0) / fd;
          }
        }
        // A «Solo micrófono» phone has no video: its audio buffer stands for it.
        final est = ((rttS / 2 + (hasVideo ? jbS + decS : audioJbS)) * 1000).round();
        if (est > 0 && latencyEstMs[peerId] != est) { latencyEstMs[peerId] = est; notifyListeners(); }
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
    final candMap = msg.candidate;
    final cand = RTCIceCandidate(
      candMap['candidate'] as String?,
      candMap['sdpMid'] as String?,
      candMap['sdpMLineIndex'] as int?,
    );
    final early = _earlyCandidates[msg.from];
    final pc = _peerConnections[msg.from];
    if (early != null || pc == null) {
      // The offer is still being applied (or has not arrived): keep it for then.
      (early ?? (_earlyCandidates[msg.from] = [])).add(cand);
      return;
    }
    try { await pc.addCandidate(cand); } catch (e) { debugPrint('[WebRtcSubscriber] candidate from ${msg.from}: $e'); }
  }

  void _handlePeerLeft(String peerId) {
    _earlyCandidates.remove(peerId);
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
    latencyEstMs.remove(peerId);
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
