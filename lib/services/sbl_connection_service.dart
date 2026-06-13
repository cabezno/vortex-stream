// =============================================================================
// SblConnectionService — Samba Broadcast Link v3 transport
//
// Protocolo SBL v3 (UDP, big-endian):
//   SblPacketHeaderV3  (32 bytes) — precede cada datagrama
//   SblFrameHeader     (32 bytes) — solo en fragmento 0 de cada frame de video
//   SblHelloPayload   (105 bytes) — enviado al conectar para handshake
//
// Flujo:
//   1. configure() → configura resolución/bitrate para native
//   2. startCamera() → abre cámara nativa, devuelve textureId para preview
//   3. connect() → native maneja Hello + video H.264 + UDP directo a engine
//              → Dart envía Keepalives por socket propio (mantiene 5s timeout)
//   4. stop() → cerrar socket Dart → detener native (stopSbl)
// =============================================================================
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum SblState { disconnected, connecting, streaming, error }

class SblConnectionService extends ChangeNotifier {
  static const _channel = MethodChannel('com.vortex.vortexcam/native');

  SblState _state    = SblState.disconnected;
  String   _errorMsg = '';
  double   _mbpsSent = 0;
  bool     _isOnAir  = false;
  int?     _textureId;

  // Video config stored from configure(), passed to native in connect()
  int _configWidth      = 1280;
  int _configHeight     = 720;
  int _configBitrateBps = 8000000;

  SblState get state     => _state;
  String   get errorMsg  => _errorMsg;
  double   get mbpsSent  => _mbpsSent;
  bool     get isOnAir   => _isOnAir;
  int?     get textureId => _textureId;
  bool     get connected => _state == SblState.streaming;

  RawDatagramSocket? _socket;
  InternetAddress?   _remoteAddr;
  int                _remotePort = 8890;
  int                _pktSeq     = 0;
  Timer?             _keepaliveTimer;
  Timer?             _statsTimer;

  // SBL v3 constants
  static const int _headerSize = 32; // SblPacketHeaderV3

  // Packet types
  static const int _ptKeepalive = 4;
  static const int _ptGoodbye   = 5;

  // ---- uint64 helper — split into two uint32 for Dart compatibility ----
  static void _setUint64(ByteData bd, int offset, int value) {
    bd.setUint32(offset,     (value >> 32) & 0xFFFFFFFF, Endian.big);
    bd.setUint32(offset + 4, value & 0xFFFFFFFF, Endian.big);
  }

  // ---- Write magic "SBL" + version=3 + packetType into header start ----
  static void _writeMagic(ByteData bd, int pktType) {
    bd.setUint8(0, 0x53); // 'S'
    bd.setUint8(1, 0x42); // 'B'
    bd.setUint8(2, 0x4C); // 'L'
    bd.setUint8(3, 3);    // version
    bd.setUint8(4, pktType);
  }

  // ---- Configure video params (stored and passed to native in connect()) ----
  Future<void> configure({
    required int width,
    required int height,
    required int targetBitrateBps,
    int fps = 30,
  }) async {
    _configWidth      = width;
    _configHeight     = height;
    _configBitrateBps = targetBitrateBps;
  }

  // ---- Open camera, get native preview texture ----
  // FIX B1: arg name 'facing' (String), return type Map not int
  Future<void> startCamera({bool frontCamera = false}) async {
    final result = await _channel.invokeMethod<Map>('startSrtCamera', {
      'facing': frontCamera ? 'front' : 'back',
    });
    _textureId = result?['textureId'] as int?;
    notifyListeners();
  }

  // ---- Connect to SAMBA desktop ----
  // FIX B4: pass width/height/bitrateBps to native
  // FIX B8: native handles Hello — Dart no longer sends Hello (avoids double Hello)
  Future<void> connect(String host, {int port = 8890, String sourceName = 'SambaAir'}) async {
    _state    = SblState.connecting;
    _errorMsg = '';
    notifyListeners();

    try {
      _remoteAddr = (await InternetAddress.lookup(host)).first;
      _remotePort = port;

      // Dart socket only for keepalives + Goodbye (native handles Hello + video)
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      // Native: Hello handshake + H.264 encode + UDP send to engine
      await _channel.invokeMethod('startSblStream', {
        'host':       host,
        'port':       port,
        'sourceName': sourceName,
        'width':      _configWidth,
        'height':     _configHeight,
        'bitrateBps': _configBitrateBps,
      });

      // Keepalive every 1s to keep engine 5s timeout from firing
      _keepaliveTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendKeepalive());

      // FIX B3: correct method name 'getSblStats' (not 'getSrtStats')
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final stats = await _channel.invokeMethod<Map>('getSblStats');
          if (stats != null) {
            _mbpsSent = (stats['bitrateMbps'] as num?)?.toDouble() ?? 0;
            notifyListeners();
          }
        } catch (_) {}
      });

      _state = SblState.streaming;
      notifyListeners();
    } catch (e) {
      _state    = SblState.error;
      _errorMsg = e.toString();
      notifyListeners();
    }
  }

  // ---- Keepalive packet — sent by Dart to hold engine 5s timeout ----
  void _sendKeepalive() {
    if (_socket == null || _remoteAddr == null) return;
    final buf = ByteData(_headerSize);
    _writeMagic(buf, _ptKeepalive);
    buf.setUint8(5, 0);
    buf.setUint16(6,  _pktSeq++, Endian.big);
    buf.setUint32(8,  0, Endian.big);
    buf.setUint16(12, 0, Endian.big);
    buf.setUint16(14, 1, Endian.big);
    _setUint64(buf, 16, DateTime.now().microsecondsSinceEpoch);
    buf.setUint16(24, 0, Endian.big);
    buf.setUint16(26, 0, Endian.big);
    buf.setUint32(28, 0, Endian.big);
    _socket!.send(buf.buffer.asUint8List(), _remoteAddr!, _remotePort);
  }

  // ---- Stop streaming and release all resources ----
  Future<void> stop() async {
    _keepaliveTimer?.cancel();
    _statsTimer?.cancel();
    _keepaliveTimer = null;
    _statsTimer     = null;

    // Send Goodbye before closing socket
    if (_socket != null && _remoteAddr != null) {
      final buf = ByteData(_headerSize);
      _writeMagic(buf, _ptGoodbye);
      buf.setUint8(5, 0);
      buf.setUint16(6,  _pktSeq++, Endian.big);
      buf.setUint32(8,  0, Endian.big);
      buf.setUint16(12, 0, Endian.big);
      buf.setUint16(14, 1, Endian.big);
      _setUint64(buf, 16, DateTime.now().microsecondsSinceEpoch);
      buf.setUint16(24, 0, Endian.big);
      buf.setUint16(26, 0, Endian.big);
      buf.setUint32(28, 0, Endian.big);
      _socket!.send(buf.buffer.asUint8List(), _remoteAddr!, _remotePort);
    }

    _socket?.close();
    _socket     = null;
    _remoteAddr = null;

    // FIX B2: correct method name 'stopSbl' (not 'stopSblStream')
    await _channel.invokeMethod('stopSbl').catchError((_) {});

    _state     = SblState.disconnected;
    _mbpsSent  = 0;
    _isOnAir   = false;
    _textureId = null;
    notifyListeners();
  }

  void setOnAir(bool active) {
    _isOnAir = active;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
