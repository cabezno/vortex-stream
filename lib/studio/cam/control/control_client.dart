import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:samba_protocol/samba_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum CameraConnectionState { disconnected, connecting, connected, error }

/// Control client for camera nodes in SAMBA Móvil Studio.
/// Connects to the switcher room host over WebSocket.
class CameraControlClient extends ChangeNotifier {
  final String peerId;
  String name;
  /// camera, or mic for a phone that only sends audio («Solo micrófono»).
  PeerRole role = PeerRole.camera;

  CameraConnectionState _state = CameraConnectionState.disconnected;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _heartbeatTimer;
  Timer? _audioTimer;
  String _errorMessage = '';

  bool _isOnAir = false;
  bool _isPreview = false;
  Layer _layer = Layer.low;
  double _currentDbfs = -50.0;
  List<Peer> _roster = [];

  // Callbacks
  void Function(SetLayerMessage msg)? onSetLayer;
  void Function(OfferMessage msg)? onOffer;
  void Function(AnswerMessage msg)? onAnswer;
  void Function(IceCandidateMessage msg)? onCandidate;

  CameraControlClient({
    required this.peerId,
    required this.name,
  });

  CameraConnectionState get state => _state;
  bool get isConnected => _state == CameraConnectionState.connected;
  bool get isOnAir => _isOnAir;
  /// Prepared to go on air next (PVW): green tally.
  bool get isPreview => _isPreview;
  /// The quality the switcher asked this camera to send.
  Layer get layer => _layer;
  double get currentDbfs => _currentDbfs;
  List<Peer> get roster => _roster;
  String get errorMessage => _errorMessage;

  /// Connect to Switcher WebSocket room server via IP, host:port, ws:// URI, or QR JSON
  Future<void> connect(String target, {int defaultPort = 8088}) async {
    _state = CameraConnectionState.connecting;
    _errorMessage = '';
    notifyListeners();

    try {
      final payload = PairingPayload.parse(target);
      final uri = Uri.parse(payload.wsUrl);
      _channel = WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (err) {
          _state = CameraConnectionState.error;
          _errorMessage = err.toString();
          _stopTimers();
          notifyListeners();
        },
        onDone: () {
          _state = CameraConnectionState.disconnected;
          _stopTimers();
          notifyListeners();
        },
      );

      // El estado debe quedar 'connected' ANTES de enviar el Join: sendMessage()
      // descarta cualquier mensaje si _state != connected. Antes el Join se mandaba
      // con _state == connecting y se perdía → el switcher nunca registraba la cámara.
      _state = CameraConnectionState.connected;

      // Send Join handshake
      sendMessage(JoinMessage(
        peerId: peerId,
        name: name,
        role: role,
      ));

      _startTimers();
      notifyListeners();
    } catch (e) {
      _state = CameraConnectionState.error;
      _errorMessage = e.toString();
      notifyListeners();
    }
  }

  void _handleMessage(dynamic raw) {
    try {
      final msg = SambaMessage.decode(raw.toString());
      switch (msg) {
        case SetLayerMessage m:
          // Quality only. On air / preview come from the roster: since PGM/PVW (2026-10-06) the preview camera is at
          // high quality too, so "high" no longer means "on air".
          if (m.peerId == peerId) {
            _layer = m.layer;
            notifyListeners();
            onSetLayer?.call(m);
          }
          break;
        case RosterMessage m:
          _roster = m.peers;
          _isOnAir = (m.activePeerId == peerId);
          _isPreview = (m.previewPeerId == peerId);
          notifyListeners();
          break;
        case OfferMessage m:
          if (m.to == peerId) {
            onOffer?.call(m);
          }
          break;
        case AnswerMessage m:
          if (m.to == peerId) {
            onAnswer?.call(m);
          }
          break;
        case IceCandidateMessage m:
          if (m.to == peerId) {
            onCandidate?.call(m);
          }
          break;
        case ByeMessage m:
          if (m.peerId == peerId) {
            disconnect();
          }
          break;
        default:
          break;
      }
    } catch (e) {
      debugPrint('[CameraControlClient] Error decoding message: $e');
    }
  }

  void sendMessage(SambaMessage msg) {
    if (_channel != null && _state == CameraConnectionState.connected) {
      _channel!.sink.add(msg.encode());
    }
  }

  /// Update the current audio dBFS level to be sent to switcher
  void updateAudioLevel(double dbfs) {
    _currentDbfs = dbfs;
    notifyListeners();
  }

  void _startTimers() {
    _stopTimers();
    // Audio telemetry timer (~100ms)
    _audioTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (isConnected) {
        sendMessage(AudioLevelMessage(peerId: peerId, dbfs: _currentDbfs));
      }
    });

    // Heartbeat timer (~3s)
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (isConnected) {
        sendMessage(HeartbeatMessage(peerId: peerId));
      }
    });
  }

  void _stopTimers() {
    _audioTimer?.cancel();
    _heartbeatTimer?.cancel();
    _audioTimer = null;
    _heartbeatTimer = null;
  }

  void disconnect() {
    _stopTimers();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _state = CameraConnectionState.disconnected;
    _isOnAir = false;
    _isPreview = false;
    _layer = Layer.low;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
