import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
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
/// VIDEO-ONLY (audio:false): su audio es el micrófono del celular, que maneja el lado
/// nativo (SwitcherMic) para el programa y para el medidor de nivel de su tarjeta.
/// El nivel NO entra al corte automático: la voz del operador la pondría al aire.
class LocalCameraSource extends ChangeNotifier {
  final RoomHost roomHost;
  final String peerId;
  String name;

  final RTCVideoRenderer renderer = RTCVideoRenderer();
  MediaStream? _stream;
  bool _active = false;
  bool _facingFront = true;
  /// A camera chosen by id (USB camera / HDMI capture plugged into the switcher, or a specific lens).
  String? deviceId;
  bool _rendererReady = false;
  Timer? _keepAlive;
  Timer? _meter;
  static const _native = MethodChannel('com.samba.studio/program_encoder');

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
    _startMeter();

    _active = true;
    notifyListeners();
  }

  /// Nivel del micrófono del switcher en la tarjeta de esta cámara (antes quedaba vacío: no hay track de audio).
  Future<void> _startMeter() async {
    try {
      if (!(await Permission.microphone.request()).isGranted) return;
      if (await _native.invokeMethod<bool>('setMicMeter', {'on': true}) != true) return;
    } catch (_) { return; }
    if (!_active) { _stopMeter(); return; }
    _meter?.cancel();
    _meter = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      final db = ((await _native.invokeMethod<double>('getMicLevel').catchError((_) => null)) ?? -100).clamp(-60.0, 0.0);
      final p = roomHost.room.peers[peerId];
      if (p == null || (p.lastAudioDbfs - db).abs() < 1) return;
      p.lastAudioDbfs = db;
      notifyListeners();
    });
  }

  void _stopMeter() {
    _meter?.cancel();
    _meter = null;
    _native.invokeMethod('setMicMeter', {'on': false}).catchError((_) => null);
  }

  Future<void> _openCamera() async {
    _stream?.getTracks().forEach((t) => t.stop());
    final constraints = <String, dynamic>{
      'audio': false,
      'video': {
        if (deviceId != null) 'deviceId': deviceId
        else 'facingMode': _facingFront ? 'user' : 'environment',
        // Plain numbers (flutter_webrtc ignores {'ideal': N} and falls back to 720p): the program is 1080p.
        'width': 1920,
        'height': 1080,
        'frameRate': 30,
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
    deviceId = null;
    _facingFront = !_facingFront;
    await _openCamera();
    notifyListeners();
  }

  /// Uses the camera [id] (CameraPicker); [front] for the mirror hint only.
  Future<void> useDevice(String id, {bool front = false}) async {
    deviceId = id;
    _facingFront = front;
    if (_active) await _openCamera();
    notifyListeners();
  }

  /// Apaga la cámara local y la saca del room.
  Future<void> stop() async {
    if (!_active) return;
    _keepAlive?.cancel();
    _keepAlive = null;
    _stopMeter();
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
    _stopMeter();
    _stream?.getTracks().forEach((t) => t.stop());
    if (_rendererReady) renderer.dispose();
    super.dispose();
  }
}
