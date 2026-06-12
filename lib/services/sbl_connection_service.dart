// =============================================================================
// SblConnectionService — Samba Broadcast Link v3 transport
//
// Protocolo SBL v3 (UDP, big-endian):
//   SblPacketHeaderV3  (32 bytes) — precede cada datagrama
//   SblFrameHeader     (32 bytes) — solo en fragmento 0 de cada frame de video
//   SblHelloPayload   (105 bytes) — enviado al conectar para handshake
//
// Flujo:
//   1. configure() → configura el encoder nativo (reutiliza canal SRT)
//   2. startCamera() → abre cámara nativa, devuelve textureId para preview
//   3. connect() → bind UDP → send Hello → esperar HelloAck (5s)
//              → nativo envía NAL H.264 via callback 'onSblFrame'
//              → Keepalive cada 1s
//   4. stop() → send Goodbye → cerrar socket → detener nativo
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
  int                _frameSeq   = 0;
  Timer?             _keepaliveTimer;
  Timer?             _statsTimer;

  // SBL v3 constants
  static const int _maxPayload   = 1200; // max video data bytes per UDP packet
  static const int _headerSize   = 32;   // SblPacketHeaderV3
  static const int _frameHdrSize = 32;   // SblFrameHeader (fragment 0 only)

  // Packet types
  static const int _ptData      = 0;
  static const int _ptHello     = 2;
  static const int _ptHelloAck  = 3;
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

  // ---- Configure native H.264 encoder (reuses SRT encoder path) ----
  Future<void> configure({
    required int width,
    required int height,
    required int targetBitrateBps,
    int fps = 30,
  }) async {
    await _channel.invokeMethod('configureSrt', {
      'width':            width,
      'height':           height,
      'targetBitrateBps': targetBitrateBps,
      'fps':              fps,
    });
  }

  // ---- Open camera, get native preview texture ----
  Future<void> startCamera({bool frontCamera = false}) async {
    final texId = await _channel.invokeMethod<int>('startSrtCamera', {
      'frontCamera': frontCamera,
    });
    _textureId = texId;
    notifyListeners();
  }

  // ---- Connect to SAMBA desktop ----
  Future<void> connect(String host, {int port = 8890, String sourceName = 'SambaAir'}) async {
    _state    = SblState.connecting;
    _errorMsg = '';
    notifyListeners();

    try {
      _remoteAddr = (await InternetAddress.lookup(host)).first;
      _remotePort = port;
      _socket     = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

      // Send Hello and wait for HelloAck (5s timeout)
      _sendHello(sourceName);

      bool ackReceived = false;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = _socket?.receive();
          if (dg != null && dg.data.length >= _headerSize) {
            // Verify magic "SBL" before checking packet type
            if (dg.data[0] == 0x53 && dg.data[1] == 0x42 && dg.data[2] == 0x4C) {
              if (dg.data[4] == _ptHelloAck) ackReceived = true;
            }
          }
        }
      });
      while (!ackReceived && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (!ackReceived) {
        debugPrint('[SambaAir][SBL] No HelloAck in 5s — proceeding anyway');
      }

      // Register native callback for H.264 NAL unit delivery
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onSblFrame') {
          final args = call.arguments as Map;
          final data = args['data']       as Uint8List;
          final isKey = args['isKeyframe'] as bool? ?? false;
          final pts   = args['ptsUs']      as int?  ?? 0;
          final w     = args['width']      as int?  ?? 1920;
          final h     = args['height']     as int?  ?? 1080;
          _sendVideoFrame(data, isKeyframe: isKey, ptsUs: pts, width: w, height: h);
        }
      });

      // Tell native to start encoding and delivering frames via 'onSblFrame'
      await _channel.invokeMethod('startSblStream', {
        'host':       host,
        'port':       port,
        'sourceName': sourceName,
      });

      // Keepalive every 1s
      _keepaliveTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendKeepalive());

      // Stats polling (reuses SRT stats channel)
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final stats = await _channel.invokeMethod<Map>('getSrtStats');
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

  // ---- Build and send the SBL Hello packet ----
  //
  // SblHelloPayload layout (105 bytes, at offset 32):
  //   [0]      version = 3
  //   [1..64]  sourceName (64 bytes, null-padded)
  //   [65]     codecCapabilities = 0x01 (H264)
  //   [66]     flags = 0x02 (hasAudio)
  //   [67]     wantEncryption = 0
  //   [68]     reserved = 0
  //   [69..72] maxBandwidthMbps = 50 (uint32 BE)
  //   [73..104] ecdhPublicKey = zeros (no encryption)
  void _sendHello(String sourceName) {
    const int helloPayloadSize = 105;
    final buf = ByteData(_headerSize + helloPayloadSize);

    _writeMagic(buf, _ptHello);
    buf.setUint8(5, 0); // streamID: VideoColor
    buf.setUint16(6,  _pktSeq++, Endian.big);
    buf.setUint32(8,  0, Endian.big); // frameSeq
    buf.setUint16(12, 0, Endian.big); // fragmentIdx
    buf.setUint16(14, 1, Endian.big); // fragmentTotal
    _setUint64(buf, 16, 0);           // timestamp
    buf.setUint16(24, helloPayloadSize, Endian.big); // payloadLen
    buf.setUint16(26, 0, Endian.big); // flags
    buf.setUint32(28, 0, Endian.big); // authTagPartial

    // Hello payload starts at byte 32
    buf.setUint8(32, 3); // version
    final nameBytes = sourceName.codeUnits.take(63).toList();
    for (int i = 0; i < 64; i++) {
      buf.setUint8(33 + i, i < nameBytes.length ? nameBytes[i] : 0);
    }
    buf.setUint8(97,  0x01); // codecCapabilities: H264
    buf.setUint8(98,  0x02); // flags: hasAudio
    buf.setUint8(99,  0);    // wantEncryption
    buf.setUint8(100, 0);    // reserved
    buf.setUint32(101, 50, Endian.big); // maxBandwidthMbps
    // ecdhPublicKey[32] at offset 105 — zero-initialized

    _socket?.send(buf.buffer.asUint8List(), _remoteAddr!, _remotePort);
  }

  // ---- Keepalive packet ----
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

  // ---- Fragment a video NAL unit and send over UDP ----
  //
  // Fragment 0 carries SblFrameHeader (32 bytes) before the NAL data.
  // Each subsequent fragment carries only NAL data.
  // Max UDP payload = _maxPayload (1200 bytes), so:
  //   fragment 0: up to 1200 - 32 = 1168 bytes of NAL
  //   fragment N: up to 1200 bytes of NAL
  void _sendVideoFrame(Uint8List nalData, {
    required bool isKeyframe,
    required int  ptsUs,
    required int  width,
    required int  height,
  }) {
    if (_socket == null || _remoteAddr == null) return;

    const int dataPerFrag0 = _maxPayload - _frameHdrSize; // 1168
    const int dataPerFragN = _maxPayload;                  // 1200

    // Slice NAL data into per-fragment chunks
    final chunks = <Uint8List>[];
    int offset = 0;
    bool first = true;
    while (offset < nalData.length) {
      final avail = first ? dataPerFrag0 : dataPerFragN;
      final len   = (nalData.length - offset).clamp(0, avail);
      chunks.add(nalData.sublist(offset, offset + len));
      offset += len;
      first   = false;
    }
    if (chunks.isEmpty) return;

    final totalFrags = chunks.length;
    final frameSeq   = _frameSeq++;
    final flags      = isKeyframe ? 0x0001 : 0x0000;

    for (int i = 0; i < chunks.length; i++) {
      final chunk      = chunks[i];
      final isFirst    = i == 0;
      final payloadLen = (isFirst ? _frameHdrSize : 0) + chunk.length;
      final pkt        = ByteData(_headerSize + payloadLen);

      // --- SblPacketHeaderV3 (32 bytes) ---
      _writeMagic(pkt, _ptData);
      pkt.setUint8(5, 0); // streamID: VideoColor
      pkt.setUint16(6,  _pktSeq++,  Endian.big);
      pkt.setUint32(8,  frameSeq,   Endian.big);
      pkt.setUint16(12, i,          Endian.big); // fragmentIdx
      pkt.setUint16(14, totalFrags, Endian.big);
      _setUint64(pkt, 16, ptsUs);
      pkt.setUint16(24, payloadLen, Endian.big);
      pkt.setUint16(26, flags,      Endian.big);
      pkt.setUint32(28, 0,          Endian.big); // authTagPartial

      int off = _headerSize;

      if (isFirst) {
        // --- SblFrameHeader (32 bytes) ---
        // [0]     codec = 0x03 (H264)
        // [1]     channels = 0 (video)
        // [2..3]  width
        // [4..5]  height
        // [6..7]  fpsNum
        // [8..9]  fpsDen
        // [10..13] flags
        // [14..17] totalFrameSize
        // [18..19] colorPrimaries = 1 (BT.709)
        // [20..21] transferFunc = 1
        // [22..23] matrixCoeff = 1
        // [24..27] sampleRate = 0
        // [28..31] reserved = 0
        pkt.setUint8( off + 0,  0x03);                   // H264
        pkt.setUint8( off + 1,  0);                      // channels (video)
        pkt.setUint16(off + 2,  width,          Endian.big);
        pkt.setUint16(off + 4,  height,         Endian.big);
        pkt.setUint16(off + 6,  30,             Endian.big); // fpsNum
        pkt.setUint16(off + 8,  1,              Endian.big); // fpsDen
        pkt.setUint32(off + 10, flags,          Endian.big);
        pkt.setUint32(off + 14, nalData.length, Endian.big); // totalFrameSize
        pkt.setUint16(off + 18, 1,              Endian.big); // BT.709 primaries
        pkt.setUint16(off + 20, 1,              Endian.big); // transfer function
        pkt.setUint16(off + 22, 1,              Endian.big); // matrix coefficients
        // sampleRate (24..27) and reserved (28..31) = 0 (zero-initialized)
        off += _frameHdrSize;
      }

      // Copy NAL chunk bytes into packet
      for (int j = 0; j < chunk.length; j++) {
        pkt.setUint8(off + j, chunk[j]);
      }

      _socket!.send(pkt.buffer.asUint8List(), _remoteAddr!, _remotePort);
    }
  }

  // ---- Stop streaming and release all resources ----
  Future<void> stop() async {
    _keepaliveTimer?.cancel();
    _statsTimer?.cancel();
    _keepaliveTimer = null;
    _statsTimer     = null;

    // Send Goodbye
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

    // Stop native encoder and clear frame callback
    await _channel.invokeMethod('stopSblStream').catchError((_) {});
    _channel.setMethodCallHandler(null);

    _state     = SblState.disconnected;
    _mbpsSent  = 0;
    _isOnAir   = false;
    _textureId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
