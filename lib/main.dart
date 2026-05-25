// =============================================================================
// VortexCam — phone camera publisher for VortexEngine.
// Scans the pairing QR shown by VortexEngine (Tools → Phone Camera), captures
// the phone camera, and publishes it over WebRTC using WHIP (H.264).
// See VORTEXCAM_PROTOCOL.md in the engine repo for the contract.
// =============================================================================
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const VortexCamApp());

class VortexCamApp extends StatelessWidget {
  const VortexCamApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VortexCam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(primary: Color(0xFF00E5FF)),
      ),
      home: const HomePage(),
    );
  }
}

/// Parsed pairing payload from the QR.
class PairConfig {
  final String whipBase;     // e.g. http://192.168.1.10:8080/whip/
  final String host;         // display name
  final int maxKbps;
  final int width, height, fps;
  PairConfig({
    required this.whipBase,
    required this.host,
    required this.maxKbps,
    required this.width,
    required this.height,
    required this.fps,
  });

  static PairConfig? tryParse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['app'] != 'vortexcam') return null;
      final whip = (j['whip'] as Map?) ?? {};
      final video = (j['video'] as Map?) ?? {};
      final url = (whip['url'] ?? '').toString();
      if (url.isEmpty) return null;
      return PairConfig(
        whipBase: url,
        host: (j['host'] ?? 'VortexEngine').toString(),
        maxKbps: (video['maxKbps'] ?? 8000) as int,
        width: (video['w'] ?? 1280) as int,
        height: (video['h'] ?? 720) as int,
        fps: (video['fps'] ?? 30) as int,
      );
    } catch (_) {
      return null;
    }
  }
}

enum CamState { idle, connecting, live, error }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _localRenderer = RTCVideoRenderer();
  final _deviceNameCtrl = TextEditingController(text: 'phone');

  PairConfig? _cfg;
  CamState _state = CamState.idle;
  String _status = '';
  bool _useFrontCamera = false;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  String? _resourceUrl; // WHIP resource (for DELETE)

  // On-screen diagnostic log (newest first). Tap the log icon to view + copy.
  final List<String> _logs = [];
  void _log(String m) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final t = '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
    debugPrint('VCAM [$t] $m');
    if (mounted) setState(() => _logs.insert(0, '[$t] $m'));
  }

  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101418),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text('Registro',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copiar'),
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: _logs.reversed.join('\n')));
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text('Log copiado al portapapeles')));
                  },
                ),
                IconButton(
                  tooltip: 'Limpiar',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    setState(() => _logs.clear());
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
            const Divider(height: 8),
            SizedBox(
              height: 380,
              child: _logs.isEmpty
                  ? const Center(
                      child: Text('Sin eventos todavía',
                          style: TextStyle(color: Colors.white38)))
                  : ListView.builder(
                      itemCount: _logs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(_logs[i],
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _log('App iniciada (v0.2.3)');
  }

  @override
  void dispose() {
    _disconnect();
    _localRenderer.dispose();
    _deviceNameCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // QR scan
  // ---------------------------------------------------------------------------
  Future<void> _scan() async {
    _log('Scan QR: pidiendo permiso de cámara...');
    if (!(await Permission.camera.request()).isGranted) {
      _log('Permiso de cámara DENEGADO');
      _setError('Permiso de cámara denegado');
      return;
    }
    if (!mounted) return;
    _log('Abriendo escáner ZXing...');
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScanPage()),
    );
    if (raw == null) {
      _log('Escáner cerrado sin leer ningún QR');
      return;
    }
    final preview = raw.length > 70 ? raw.substring(0, 70) : raw;
    _log('QR leído (${raw.length} chars): $preview');
    final cfg = PairConfig.tryParse(raw);
    if (cfg == null) {
      _log('El QR NO es un código de emparejamiento VortexCam');
      _setError('El QR no es un código VortexCam');
      return;
    }
    _log('Emparejado. whip=${cfg.whipBase}');
    setState(() {
      _cfg = cfg;
      _state = CamState.idle;
      _status = 'Emparejado con ${cfg.host}';
    });
  }

  // Manual pairing: type the WHIP endpoint shown as text in the VortexEngine
  // panel (http://<ip>:8080/whip/). Lets you connect without the QR scanner.
  Future<void> _manualEntry() async {
    final ctrl = TextEditingController(
      text: _cfg?.whipBase ?? 'http://192.168.1.2:8080/whip/',
    );
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Endpoint WHIP manual'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Copiá la URL que muestra VortexEngine en\n'
                'Herramientas → Cámara de celular (WHIP).',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'http://<ip>:8080/whip/',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Usar')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    _log('Endpoint manual ingresado: $url');
    setState(() {
      _cfg = PairConfig(
        whipBase: url,
        host: 'Manual',
        maxKbps: 8000,
        width: 1280,
        height: 720,
        fps: 30,
      );
      _state = CamState.idle;
      _status = 'Endpoint manual listo → tocá Go live';
    });
  }

  // ---------------------------------------------------------------------------
  // Connect (WHIP publish)
  // ---------------------------------------------------------------------------
  Future<void> _connect() async {
    final cfg = _cfg;
    if (cfg == null) {
      _log('Go live SIN endpoint (escaneá o ingresá manual primero)');
      _setError('Primero escaneá el QR o ingresá el endpoint');
      return;
    }
    _log('Go live: pidiendo permisos...');
    if (!(await Permission.camera.request()).isGranted) {
      _log('Permiso de cámara DENEGADO');
      _setError('Permiso de cámara denegado');
      return;
    }
    await Permission.microphone.request(); // optional (audio added later)

    setState(() { _state = CamState.connecting; _status = 'Iniciando cámara...'; });
    try {
      // 1) Camera
      _log('getUserMedia (${cfg.width}x${cfg.height}@${cfg.fps})...');
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': _useFrontCamera ? 'user' : 'environment',
          'width': {'ideal': cfg.width},
          'height': {'ideal': cfg.height},
          'frameRate': {'ideal': cfg.fps},
        },
      });
      _localRenderer.srcObject = _localStream;
      _log('Cámara OK (${_localStream!.getVideoTracks().length} pista video)');

      // 2) PeerConnection (sendonly video)
      _pc = await createPeerConnection({
        'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}],
        'sdpSemantics': 'unified-plan',
      });
      _log('PeerConnection creada');
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      setState(() => _status = 'Negociando...');

      // 3) Offer → force H.264 (engine decoder is H.264)
      final offer = await _pc!.createOffer({});
      final munged = _preferH264(offer.sdp ?? '');
      await _pc!.setLocalDescription(RTCSessionDescription(munged, 'offer'));
      _log('Offer creada, esperando ICE...');

      // 4) Wait for ICE gathering to complete (non-trickle WHIP)
      await _waitIceComplete(_pc!);
      final local = await _pc!.getLocalDescription();
      final localSdp = local?.sdp ?? munged;

      // 5) POST the offer to <whipBase><deviceName>
      final dev = _deviceNameCtrl.text.trim().isEmpty ? 'phone' : _deviceNameCtrl.text.trim();
      final base = _normalizeWhipBase(cfg.whipBase);
      final url = '$base$dev';
      _log('POST $url (SDP ${localSdp.length} bytes)...');
      setState(() => _status = 'Conectando a $url ...');
      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/sdp'},
        body: localSdp,
      ).timeout(const Duration(seconds: 12));
      _log('HTTP ${res.statusCode} (respuesta ${res.body.length} bytes)');
      if (res.statusCode != 201 && res.statusCode != 200) {
        throw 'El servidor respondió ${res.statusCode}';
      }
      // 6) Apply the SDP answer
      await _pc!.setRemoteDescription(RTCSessionDescription(res.body, 'answer'));
      _resourceUrl = res.headers['location'] != null
          ? _resolveLocation(url, res.headers['location']!)
          : url;
      _log('Answer aplicada → EN VIVO');
      setState(() { _state = CamState.live; _status = 'EN VIVO → ${cfg.host}'; });
    } catch (e) {
      _log('ERROR: $e');
      _setError('Falló la conexión: $e');
      await _disconnect();
    }
  }

  Future<void> _disconnect() async {
    try {
      if (_resourceUrl != null) {
        // best-effort WHIP teardown
        await http.delete(Uri.parse(_resourceUrl!)).timeout(
            const Duration(seconds: 2), onTimeout: () => http.Response('', 204));
      }
    } catch (_) {}
    _resourceUrl = null;
    try { await _pc?.close(); } catch (_) {}
    _pc = null;
    try {
      for (final t in _localStream?.getTracks() ?? const <MediaStreamTrack>[]) {
        await t.stop();
      }
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    _localRenderer.srcObject = null;
    if (mounted) {
      setState(() {
        if (_state != CamState.error) _state = CamState.idle;
        if (_state == CamState.idle) _status = _cfg == null ? '' : 'Paired with ${_cfg!.host}';
      });
    }
  }

  void _setError(String msg) {
    if (mounted) setState(() { _state = CamState.error; _status = msg; });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  // Wait until ICE gathering completes (or 3s timeout) so the offer carries
  // all candidates — VortexEngine's WHIP server expects a complete SDP.
  Future<void> _waitIceComplete(RTCPeerConnection pc) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    final c = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !c.isCompleted) c.complete();
    };
    await c.future.timeout(const Duration(seconds: 3), onTimeout: () {});
  }

  // Make a typed/scanned WHIP base robust: trim, drop stray leading slashes or
  // spaces, ensure an http:// scheme and a trailing slash. Fixes inputs like
  // "/http://ip:8080/whip/" (the "No host specified in URI" error).
  String _normalizeWhipBase(String raw) {
    var s = raw.trim();
    s = s.replaceFirst(RegExp(r'^[/\s]+'), '');
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    if (!s.endsWith('/')) s = '$s/';
    return s;
  }

  String _resolveLocation(String base, String location) {
    if (location.startsWith('http')) return location;
    final u = Uri.parse(base);
    return '${u.scheme}://${u.host}:${u.port}$location';
  }

  // Keep only H.264 (and its RTX) payload types in the video m-line so the
  // engine (which decodes H.264) always receives a compatible stream.
  String _preferH264(String sdp) {
    final lines = sdp.split(RegExp(r'\r\n|\n'));
    int mIdx = lines.indexWhere((l) => l.startsWith('m=video'));
    if (mIdx < 0) return sdp;

    // payload type → codec name; rtx apt mapping
    final rtpmap = <String, String>{};
    final apt = <String, String>{}; // rtx pt → referenced pt
    final reFmtpApt = RegExp(r'a=fmtp:(\d+).*apt=(\d+)');
    final reRtpmap = RegExp(r'a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/');
    for (final l in lines) {
      final m = reRtpmap.firstMatch(l);
      if (m != null) rtpmap[m.group(1)!] = m.group(2)!.toUpperCase();
      final a = reFmtpApt.firstMatch(l);
      if (a != null) apt[a.group(1)!] = a.group(2)!;
    }
    // H.264 payload types (+ their rtx)
    final keep = <String>{};
    rtpmap.forEach((pt, name) { if (name == 'H264') keep.add(pt); });
    if (keep.isEmpty) return sdp; // no H264 offered — leave as-is
    apt.forEach((rtxPt, refPt) { if (keep.contains(refPt)) keep.add(rtxPt); });

    // Rewrite m=video line: "m=video <port> <proto> <pt...>"
    final parts = lines[mIdx].split(' ');
    final header = parts.sublist(0, 3);
    final kept = parts.sublist(3).where(keep.contains).toList();
    lines[mIdx] = ([...header, ...kept]).join(' ');

    // Drop a=rtpmap/fmtp/rtcp-fb lines for non-kept payload types.
    final rePt = RegExp(r'a=(rtpmap|fmtp|rtcp-fb):(\d+)');
    final out = <String>[];
    for (final l in lines) {
      final m = rePt.firstMatch(l);
      if (m != null && !keep.contains(m.group(2))) continue;
      out.add(l);
    }
    return out.join('\r\n');
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final live = _state == CamState.live;
    final connecting = _state == CamState.connecting;
    return Scaffold(
      appBar: AppBar(
        title: const Text('VortexCam'),
        actions: [
          if (live)
            IconButton(
              icon: Icon(_useFrontCamera ? Icons.camera_front : Icons.camera_rear),
              onPressed: () async { await _flipCamera(); },
            ),
          IconButton(
            tooltip: 'Registro / log',
            icon: const Icon(Icons.article_outlined),
            onPressed: _showLogs,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Preview
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: live ? const Color(0xFF34D399) : Colors.white12),
                ),
                clipBehavior: Clip.antiAlias,
                child: (_localStream != null)
                    ? RTCVideoView(_localRenderer, mirror: _useFrontCamera,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                    : const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Text(
                            'Sin video aún.\nEscaneá el QR (o ingresá el endpoint) y tocá Go live.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            // Status
            Text(_status,
                style: TextStyle(
                    color: _state == CamState.error ? const Color(0xFFF87171)
                        : live ? const Color(0xFF34D399) : Colors.white70)),
            const SizedBox(height: 12),
            // Device name
            TextField(
              controller: _deviceNameCtrl,
              enabled: !live && !connecting,
              decoration: const InputDecoration(
                labelText: 'Camera name', border: OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 12),
            // Buttons
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (live || connecting) ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _cfg == null
                      ? null
                      : (live ? _disconnect : (connecting ? null : _connect)),
                  icon: Icon(live ? Icons.stop : Icons.videocam),
                  label: Text(live ? 'Disconnect' : connecting ? 'Connecting...' : 'Go live'),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: (live || connecting) ? null : _manualEntry,
              icon: const Icon(Icons.keyboard),
              label: const Text('Ingresar endpoint WHIP manualmente'),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Future<void> _flipCamera() async {
    if (_localStream == null) return;
    final videoTrack = _localStream!.getVideoTracks().firstOrNull;
    if (videoTrack == null) return;
    try {
      await Helper.switchCamera(videoTrack);
      setState(() => _useFrontCamera = !_useFrontCamera);
    } catch (_) {}
  }
}

extension _FirstOrNull<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

// QR scan screen — ZXing (flutter_zxing). Decodes with the ZXing C++ library
// via FFI; uses the `camera` plugin for the preview. No ML Kit / Play Services,
// so it sidesteps the ML Kit init crash on devices where mobile_scanner failed.
class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Escaneá el QR de VortexEngine')),
      backgroundColor: Colors.black,
      body: ReaderWidget(
        // ReaderWidget brings its own camera preview + scan overlay.
        // Defaults only scan the centre 50% (cropPercent 0.5) with tryHarder off,
        // so a dense pairing QR that fills the frame often won't decode. Widen the
        // scan area and let ZXing work harder.
        cropPercent: 0.9,
        tryHarder: true,
        tryInverted: true,
        scanDelay: const Duration(milliseconds: 400),
        onScan: (code) async {
          if (_done) return;
          final v = code.text;
          if (code.isValid && v != null && v.isNotEmpty) {
            _done = true;
            if (mounted) Navigator.of(context).pop(v);
          }
        },
      ),
    );
  }
}
