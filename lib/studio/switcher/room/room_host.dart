import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:samba_protocol/samba_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Hosts the local Room and WebSocket control server on the Switcher device.
/// Operates without any external internet server.
class RoomHost extends ChangeNotifier {
  final int port;
  final Room room;
  HttpServer? _server;
  final Map<String, WebSocketChannel> _clientChannels = {};
  Timer? _pruneTimer;

  // Callbacks
  void Function(String peerId, double dbfs)? onAudioLevel;
  void Function(Peer peer)? onPeerJoined;
  void Function(String peerId)? onPeerLeft;
  void Function(OfferMessage offer)? onWebRtcOffer;
  void Function(IceCandidateMessage candidate)? onWebRtcCandidate;

  RoomHost({
    this.port = 8088,
    String roomId = 'samba_studio',
  }) : room = Room(id: roomId);

  bool get isRunning => _server != null;
  List<Peer> get cameras => room.peers.values.where((p) => p.role == PeerRole.camera).toList();
  String? get activePeerId => room.activePeerId;
  String? get previewPeerId => room.previewPeerId;

  /// What each camera reported about itself (capture delay, microphone, max resolution): see CamInfoMessage.
  final Map<String, CamInfoMessage> camInfo = {};
  void Function(CamInfoMessage info)? onCamInfo;

  /// Cameras the program composition needs at full quality besides PGM and PVW (the second camera of a split / PiP),
  /// set by the ProgramMixer.
  Set<String> _extraHigh = {};
  set extraHigh(Set<String> ids) {
    if (setEquals(ids, _extraHigh)) return;
    _extraHigh = Set.of(ids);
    _applyLayers();
  }

  /// Start the local WebSocket & HTTP server
  Future<void> start() async {
    if (_server != null) return;

    final wsHandler = webSocketHandler((WebSocketChannel channel) {
      _handleNewConnection(channel);
    });

    final handler = const Pipeline()
        .addMiddleware(logRequests())
        .addHandler((Request request) {
      if (request.url.path == 'ws') {
        return wsHandler(request);
      }
      if (request.url.path == 'status') {
        return Response.ok(
          room.toJson().toString(),
          headers: {'content-type': 'application/json'},
        );
      }
      return Response.ok('SAMBA Móvil Studio Room Server active');
    });

    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    debugPrint('[RoomHost] Server listening on ws://0.0.0.0:$port/ws');

    _startPruneTimer();
    notifyListeners();
  }

  void _handleNewConnection(WebSocketChannel channel) {
    String? assignedPeerId;

    channel.stream.listen(
      (dynamic data) {
        try {
          final msg = SambaMessage.decode(data.toString());
          switch (msg) {
            case JoinMessage m:
              assignedPeerId = m.peerId;
              _clientChannels[m.peerId] = channel;
              final peer = Peer(
                id: m.peerId,
                name: m.name,
                role: m.role,
                connected: true,
                activeLayer: Layer.low,
              );
              room.peers[m.peerId] = peer;
              onPeerJoined?.call(peer);
              // A camera that (re)joins must hear its layer even if it is the same as the default: it may have
              // been at high quality in a previous session.
              _applyLayers(force: {m.peerId});
              broadcastRoster();
              notifyListeners();
              break;

            case CamInfoMessage m:
              camInfo[m.peerId] = m;
              onCamInfo?.call(m);
              notifyListeners();
              break;

            case AudioLevelMessage m:
              final p = room.peers[m.peerId];
              if (p != null) {
                p.lastAudioDbfs = m.dbfs;
                p.lastSeen = DateTime.now();
                onAudioLevel?.call(m.peerId, m.dbfs);
              }
              break;

            case HeartbeatMessage m:
              final p = room.peers[m.peerId];
              if (p != null) {
                p.lastSeen = DateTime.now();
              }
              break;

            case OfferMessage m:
              onWebRtcOffer?.call(m);
              break;

            case IceCandidateMessage m:
              onWebRtcCandidate?.call(m);
              break;

            case ByeMessage m:
              _removePeer(m.peerId);
              break;

            default:
              break;
          }
        } catch (e) {
          debugPrint('[RoomHost] Error handling client message: $e');
        }
      },
      onDone: () {
        if (assignedPeerId != null) {
          _removePeer(assignedPeerId!);
        }
      },
      onError: (err) {
        if (assignedPeerId != null) {
          _removePeer(assignedPeerId!);
        }
      },
    );
  }

  /// Registra un peer LOCAL (la cámara del propio switcher): NO tiene canal WS,
  /// es captura local. Aparece en la grilla/roster/director como una fuente más.
  void addLocalPeer(Peer peer) {
    room.peers[peer.id] = peer;
    onPeerJoined?.call(peer);
    broadcastRoster();
    notifyListeners();
  }

  /// Mantiene vivo un peer local (evita que el prune-timer lo borre por >10s).
  void touchPeer(String peerId) {
    room.peers[peerId]?.lastSeen = DateTime.now();
  }

  /// Quita un peer local del room.
  void removeLocalPeer(String peerId) {
    _removePeer(peerId);
  }

  /// Sends a direct message to a specific connected peer
  void sendToPeer(String peerId, SambaMessage msg) {
    final channel = _clientChannels[peerId];
    if (channel != null) {
      channel.sink.add(msg.encode());
    }
  }

  /// Broadcasts the current Roster to all connected cameras
  void broadcastRoster() {
    final rosterMsg = RosterMessage(
      peers: room.peers.values.toList(),
      activePeerId: room.activePeerId,
      previewPeerId: room.previewPeerId,
    );
    final encoded = rosterMsg.encode();
    for (final ch in _clientChannels.values) {
      ch.sink.add(encoded);
    }
  }

  /// PGM / PVW quality policy (2026-10-06): the on-air camera, the one in preview and the second camera of a
  /// split / PiP send at high quality; every other camera at the low layer. The cut PVW → PGM is then instant (both
  /// already decoded in high), and a phone switcher only decodes two full streams whatever the number of cameras.
  /// Only changes are sent, except to the cameras in [force] (just joined).
  void _applyLayers({Set<String> force = const {}}) {
    final high = {..._extraHigh, if (room.activePeerId != null) room.activePeerId!, if (room.previewPeerId != null) room.previewPeerId!};
    var changed = false;
    for (final p in room.peers.values) {
      if (p.role != PeerRole.camera) continue;
      final want = high.contains(p.id) ? Layer.high : Layer.low;
      if (want == p.activeLayer && !force.contains(p.id)) continue;
      p.activeLayer = want;
      sendToPeer(p.id, SetLayerMessage(peerId: p.id, layer: want));
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Update the active on-air camera ID and coordinate layer switches
  void setActiveCamera(String? newActivePeerId) {
    if (room.activePeerId == newActivePeerId) return;
    room.activePeerId = newActivePeerId;
    if (room.previewPeerId == newActivePeerId) room.previewPeerId = null;
    _applyLayers();
    broadcastRoster();
    notifyListeners();
  }

  /// Prepare a camera to go on air next (PVW). null clears it. The on-air camera cannot be in preview.
  void setPreviewCamera(String? peerId) {
    if (peerId != null && (peerId == room.activePeerId || !room.peers.containsKey(peerId))) peerId = null;
    if (room.previewPeerId == peerId) return;
    room.previewPeerId = peerId;
    _applyLayers();
    broadcastRoster();
    notifyListeners();
  }

  void _removePeer(String peerId) {
    _clientChannels.remove(peerId);
    final removed = room.peers.remove(peerId);
    if (removed != null) {
      onPeerLeft?.call(peerId);
      camInfo.remove(peerId);
      if (room.activePeerId == peerId) {
        room.activePeerId = null;
      }
      if (room.previewPeerId == peerId) room.previewPeerId = null;
      broadcastRoster();
      notifyListeners();
    }
  }

  void _startPruneTimer() {
    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now();
      final staleIds = <String>[];
      for (final p in room.peers.values) {
        if (now.difference(p.lastSeen).inSeconds > 10) {
          staleIds.add(p.id);
        }
      }
      for (final id in staleIds) {
        _removePeer(id);
      }
    });
  }

  /// Stop server and disconnect all peers
  Future<void> stop() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    final channels = _clientChannels.values.toList();
    _clientChannels.clear();
    for (final ch in channels) {
      await ch.sink.close();
    }
    await _server?.close(force: true);
    _server = null;
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
