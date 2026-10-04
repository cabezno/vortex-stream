import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:samba_protocol/samba_protocol.dart';
import '../room/room_host.dart';

/// Cámara LOCAL del propio switcher, integrada como una fuente de video más.
///
/// Es captura LOCAL vía getUserMedia: NO usa WebRTC, ni encode, ni red — cero
/// latencia y cero ancho de banda para esta cámara. Se registra como un "peer
/// virtual" en el [RoomHost] para aparecer en la grilla/roster junto a las
/// cámaras remotas y poder cortarla desde el Director igual que a las demás.
///
/// Primer paso VIDEO-ONLY (audio:false) para evitar realimentación del micrófono
/// del operador; el mic local + VAD para el Audio Switcher queda como follow-up.
class LocalCameraSource extends ChangeNotifier {
  final RoomHost roomHost;
  final String peerId;
  String name;

  final RTCVideoRenderer renderer = RTCVideoRenderer();
  MediaStream? _stream;
  bool _active = false;
  bool _facingFront = true;
  bool _rendererReady = false;
  Timer? _keepAlive;

  LocalCameraSource({
    required this.roomHost,
    this.peerId = 'local_switcher_cam',
    this.name = 'Cámara local',
  });

  bool get isActive => _active;
  bool get facingFront => _facingFront;
  MediaStream? get stream => _stream;

  /// Enciende la cámara local y la publica como fuente en el room.
  Future<void> start() async {
    if (_active) return;
    if (!_rendererReady) {
      await renderer.initialize();
      _rendererReady = true;
    }
    await _openCamera();

    roomHost.addLocalPeer(
      Peer(id: peerId, name: name, role: PeerRole.camera, connected: true),
    );
    // El prune-timer del room borra peers con lastSeen > 10s. Este peer no manda
    // heartbeats por WS (es local), así que lo mantenemos vivo nosotros.
    _keepAlive = Timer.periodic(const Duration(seconds: 3), (_) {
      roomHost.touchPeer(peerId);
    });

    _active = true;
    notifyListeners();
  }

  Future<void> _openCamera() async {
    _stream?.getTracks().forEach((t) => t.stop());
    final constraints = <String, dynamic>{
      'audio': false,
      'video': {
        'facingMode': _facingFront ? 'user' : 'environment',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      },
    };
    _stream = await navigator.mediaDevices.getUserMedia(constraints);
    renderer.srcObject = _stream;
  }

  /// Alterna cámara frontal/trasera re-abriendo el capturer. (El giro in-place
  /// con Helper.switchCamera dejaba el capturer en 0 frames en algunos equipos;
  /// re-abrir es más confiable. Acá es captura local sin sender, así que basta
  /// con re-apuntar el renderer al stream nuevo.)
  Future<void> flip() async {
    if (!_active) return;
    _facingFront = !_facingFront;
    await _openCamera();
    notifyListeners();
  }

  /// Apaga la cámara local y la saca del room.
  Future<void> stop() async {
    if (!_active) return;
    _keepAlive?.cancel();
    _keepAlive = null;
    _stream?.getTracks().forEach((t) => t.stop());
    _stream = null;
    renderer.srcObject = null;
    roomHost.removeLocalPeer(peerId);
    _active = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _keepAlive?.cancel();
    _keepAlive = null;
    _stream?.getTracks().forEach((t) => t.stop());
    if (_rendererReady) renderer.dispose();
    super.dispose();
  }
}
