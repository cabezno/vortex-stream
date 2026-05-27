// =============================================================================
// VortexCam v0.3.0 — phone camera publisher for VortexEngine (WHIP/WebRTC).
//
// Connect screen: scan QR or enter endpoint manually, pick resolution, Go live.
// Live screen: fullscreen camera preview with overlay (flip, torch, disconnect),
//              ON AIR badge, latency indicator.
//
// WebRTC: sendonly H.264 via addTrack + WHIP POST. Same proven path as v0.2.3.
// =============================================================================
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        colorScheme: const ColorScheme.dark(primary: Color(0xFF00BBDD)),
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0D0D0D),
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Resolution presets
// ---------------------------------------------------------------------------
enum _Res { r720p, r1080p, r4k }

extension _ResExt on _Res {
  String get label => switch (this) {
    _Res.r720p  => '720p',
    _Res.r1080p => '1080p',
    _Res.r4k    => '4K',
  };
  int get w => switch (this) { _Res.r720p => 1280, _Res.r1080p => 1920, _Res.r4k => 3840 };
  int get h => switch (this) { _Res.r720p => 720,  _Res.r1080p => 1080, _Res.r4k => 2160 };
}

// ---------------------------------------------------------------------------
// Pairing config parsed from QR
// ---------------------------------------------------------------------------
class PairConfig {
  final String whipBase; // e.g. http://192.168.1.10:8080/whip/
  final String host;
  PairConfig({required this.whipBase, required this.host});

  static PairConfig? tryParse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['app'] != 'vortexcam') return null;
      final whip = (j['whip'] as Map?) ?? {};
      final url  = (whip['url'] ?? '').toString();
      if (url.isEmpty) return null;
      return PairConfig(
        whipBase: url,
        host:     (j['host'] ?? 'VortexEngine').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// App states
// ---------------------------------------------------------------------------
enum CamState { idle, connecting, live, error }

// ---------------------------------------------------------------------------
// Main widget
// ---------------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _localRenderer  = RTCVideoRenderer();
  final _deviceNameCtrl = TextEditingController(text: 'phone');

  PairConfig? _cfg;
  CamState    _state          = CamState.idle;
  String      _status         = '';
  bool        _useFrontCamera = false;
  bool        _torchOn        = false;
  bool        _showControls   = true;
  bool        _isOnAir        = false;
  int         _latencyMs      = 0;
  _Res        _resolution     = _Res.r1080p;

  RTCPeerConnection? _pc;
  MediaStream?       _localStream;
  String?            _resourceUrl;
  Timer?             _pollingTimer;

  final List<String> _logs = [];

  void _log(String m) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final t = '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
    debugPrint('VCAM [$t] $m');
    if (mounted) setState(() => _logs.insert(0, '[$t] $m'));
  }

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _log('App iniciada (v0.3.0)');
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
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
      _log('QR no reconocido como código VortexCam');
      _setError('El QR no es un código VortexCam');
      return;
    }
    _log('Emparejado. whip=${cfg.whipBase}');
    setState(() {
      _cfg    = cfg;
      _state  = CamState.idle;
      _status = 'Emparejado con ${cfg.host}';
    });
  }

  // Manual pairing fallback
  Future<void> _manualEntry() async {
    final ctrl = TextEditingController(
        text: _cfg?.whipBase ?? 'http://192.168.1.2:8080/whip/');
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Endpoint WHIP manual'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Copiá la URL que muestra VortexEngine en\n'
              'Herramientas → Cámara de celular (WHIP).',
              style: TextStyle(fontSize: 12),
            ),
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
    _log('Endpoint manual: $url');
    setState(() {
      _cfg    = PairConfig(whipBase: url, host: 'Manual');
      _state  = CamState.idle;
      _status = 'Endpoint manual listo → tocá Go live';
    });
  }

  // ---------------------------------------------------------------------------
  // Connect (WHIP publish) — same proven flow as v0.2.3
  // ---------------------------------------------------------------------------
  Future<void> _connect() async {
    final cfg = _cfg;
    if (cfg == null) {
      _log('Go live SIN endpoint');
      _setError('Primero escaneá el QR o ingresá el endpoint');
      return;
    }
    _log('Go live: pidiendo permisos...');
    if (!(await Permission.camera.request()).isGranted) {
      _log('Permiso DENEGADO');
      _setError('Permiso de cámara denegado');
      return;
    }
    await Permission.microphone.request();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() { _state = CamState.connecting; _status = 'Iniciando cámara...'; });

    try {
      // 1) Camera
      _log('getUserMedia (${_resolution.w}x${_resolution.h}@60)...');
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': _useFrontCamera ? 'user' : 'environment',
          'width':  {'ideal': _resolution.w},
          'height': {'ideal': _resolution.h},
          'frameRate': {'ideal': 60},
        },
      });
      _localRenderer.srcObject = _localStream;
      _log('Cámara OK (${_localStream!.getVideoTracks().length} pista video)');

      // 2) PeerConnection — sendonly video
      _pc = await createPeerConnection({
        'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}],
        'sdpSemantics': 'unified-plan',
      });
      _log('PeerConnection creada');
      for (final track in _localStream!.getTracks()) {
        if (track.kind == 'video') {
          // addTransceiver with scaleResolutionDownBy=1.0 prevents Android's
          // quality scaler from reducing resolution when RTCP REMB is absent.
          await _pc!.addTransceiver(
            track: track,
            kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
            init: RTCRtpTransceiverInit(
              direction: TransceiverDirection.SendOnly,
              sendEncodings: [
                RTCRtpEncoding(
                  maxBitrate:            8000000,
                  maxFramerate:          60,
                  scaleResolutionDownBy: 1.0,
                ),
              ],
            ),
          );
        } else {
          await _pc!.addTrack(track, _localStream!);
        }
      }

      setState(() => _status = 'Negociando...');

      // 3) SDP offer — force H.264 (engine only decodes H.264)
      final offer  = await _pc!.createOffer({});
      final munged = _preferH264(offer.sdp ?? '');
      await _pc!.setLocalDescription(RTCSessionDescription(munged, 'offer'));
      _log('Offer creada, esperando ICE gathering...');

      // 4) Wait for ICE gathering (non-trickle WHIP needs all candidates in offer)
      await _waitIceComplete(_pc!);
      final local    = await _pc!.getLocalDescription();
      final localSdp = local?.sdp ?? munged;

      // 5) WHIP POST
      final dev  = _deviceNameCtrl.text.trim().isEmpty ? 'phone' : _deviceNameCtrl.text.trim();
      final base = _normalizeWhipBase(cfg.whipBase);
      final url  = '$base$dev';
      _log('POST $url (${localSdp.length} bytes SDP)...');
      setState(() => _status = 'Conectando...');
      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/sdp'},
        body: localSdp,
      ).timeout(const Duration(seconds: 12));
      _log('HTTP ${res.statusCode} (${res.body.length} bytes respuesta)');
      if (res.statusCode != 201 && res.statusCode != 200) {
        throw 'El servidor respondió ${res.statusCode}';
      }

      // 6) Apply SDP answer
      await _pc!.setRemoteDescription(RTCSessionDescription(res.body, 'answer'));
      _resourceUrl = res.headers['location'] != null
          ? _resolveLocation(url, res.headers['location']!)
          : url;
      _log('Answer aplicada → EN VIVO');
      setState(() {
        _state        = CamState.live;
        _status       = 'EN VIVO → ${cfg.host}';
        _showControls = true;
      });
      _startPolling(cfg);
    } catch (e) {
      _log('ERROR: $e');
      _setError('Falló la conexión: $e');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await _disconnect();
    }
  }

  // Poll engine /status every 3s: ON AIR flag + latency measurement
  void _startPolling(PairConfig cfg) {
    final base = _normalizeWhipBase(cfg.whipBase);
    final uri  = Uri.parse(base);
    final statusUrl = Uri(scheme: uri.scheme, host: uri.host, port: uri.port, path: '/status');
    final dev  = _deviceNameCtrl.text.trim().isEmpty ? 'phone' : _deviceNameCtrl.text.trim();

    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_state != CamState.live || !mounted) return;
      try {
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final r  = await http.get(statusUrl).timeout(const Duration(seconds: 2));
        final ms = DateTime.now().millisecondsSinceEpoch - t0;
        if (r.statusCode == 200 && mounted) {
          bool onAir = false;
          try {
            final body = jsonDecode(r.body) as Map<String, dynamic>;
            onAir = body['active_source'] == dev;
          } catch (_) {}
          setState(() { _isOnAir = onAir; _latencyMs = ms; });
        }
      } catch (_) {}
    });
  }

  // ---------------------------------------------------------------------------
  // Disconnect
  // ---------------------------------------------------------------------------
  Future<void> _disconnect() async {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    try {
      if (_resourceUrl != null) {
        await http.delete(Uri.parse(_resourceUrl!)).timeout(
            const Duration(seconds: 2),
            onTimeout: () => http.Response('', 204));
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
    _localStream             = null;
    _localRenderer.srcObject = null;
    _torchOn   = false;
    _isOnAir   = false;
    _latencyMs = 0;

    if (mounted) {
      setState(() {
        if (_state != CamState.error) _state = CamState.idle;
        if (_state == CamState.idle) {
          _status = _cfg == null ? '' : 'Emparejado con ${_cfg!.host}';
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Torch
  // ---------------------------------------------------------------------------
  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track != null) {
      try {
        await track.applyConstraints({'torch': _torchOn});
      } catch (e) {
        _log('Torch: $e');
      }
    }
    setState(() {});
  }

  void _setError(String msg) {
    if (mounted) setState(() { _state = CamState.error; _status = msg; });
  }

  // ---------------------------------------------------------------------------
  // WebRTC helpers (unchanged from v0.2.3)
  // ---------------------------------------------------------------------------
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

  String _normalizeWhipBase(String raw) {
    var s = raw.trim();
    s = s.replaceFirst(RegExp(r'^[/\s]+'), '');
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    if (!s.endsWith('/')) s = '$s/';
    return s;
  }

  String _resolveLocation(String base, String location) {
    if (location.startsWith('http')) return location;
    final u = Uri.parse(base);
    return '${u.scheme}://${u.host}:${u.port}$location';
  }

  String _preferH264(String sdp) {
    final lines = sdp.split(RegExp(r'\r\n|\n'));
    final mIdx  = lines.indexWhere((l) => l.startsWith('m=video'));
    if (mIdx < 0) return sdp;
    final rtpmap    = <String, String>{};
    final apt       = <String, String>{};
    final reFmtpApt = RegExp(r'a=fmtp:(\d+).*apt=(\d+)');
    final reRtpmap  = RegExp(r'a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/');
    for (final l in lines) {
      final m = reRtpmap.firstMatch(l);
      if (m != null) rtpmap[m.group(1)!] = m.group(2)!.toUpperCase();
      final a = reFmtpApt.firstMatch(l);
      if (a != null) apt[a.group(1)!] = a.group(2)!;
    }
    final keep = <String>{};
    rtpmap.forEach((pt, name) { if (name == 'H264') keep.add(pt); });
    if (keep.isEmpty) return sdp;
    apt.forEach((rtxPt, refPt) { if (keep.contains(refPt)) keep.add(rtxPt); });
    final parts  = lines[mIdx].split(' ');
    final header = parts.sublist(0, 3);
    final kept   = parts.sublist(3).where(keep.contains).toList();
    lines[mIdx]  = ([...header, ...kept]).join(' ');
    final rePt = RegExp(r'a=(rtpmap|fmtp|rtcp-fb):(\d+)');
    final out  = <String>[];
    for (final l in lines) {
      final m = rePt.firstMatch(l);
      if (m != null && !keep.contains(m.group(2))) continue;
      out.add(l);
    }
    return out.join('\r\n');
  }

  // ---------------------------------------------------------------------------
  // Log panel
  // ---------------------------------------------------------------------------
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
            Row(children: [
              const Text('Registro',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copiar'),
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: _logs.reversed.join('\n')));
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
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
            ]),
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

  // ---------------------------------------------------------------------------
  // Resolution picker (available before connecting)
  // ---------------------------------------------------------------------------
  void _showResolutionPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _Res.values
              .map((r) => ListTile(
                    title: Text(
                        switch (r) {
                          _Res.r720p  => '720p  (1280 × 720)',
                          _Res.r1080p => '1080p (1920 × 1080)',
                          _Res.r4k    => '4K    (3840 × 2160)',
                        },
                        style: const TextStyle(color: Colors.white)),
                    trailing: _resolution == r
                        ? const Icon(Icons.check, color: Color(0xFF00BBDD))
                        : null,
                    onTap: () {
                      setState(() => _resolution = r);
                      Navigator.pop(context);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI root
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return _state == CamState.live ? _buildLiveView() : _buildConnectView();
  }

  // ---- Connect screen ------------------------------------------------
  Widget _buildConnectView() {
    final connecting = _state == CamState.connecting;
    return Scaffold(
      appBar: AppBar(
        title: const Text('VortexCam'),
        actions: [
          IconButton(
            tooltip: 'Registro',
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
              // Status / error
              if (_status.isNotEmpty) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _state == CamState.error
                        ? Colors.red.withOpacity(0.15)
                        : Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _status,
                    style: TextStyle(
                      color: _state == CamState.error
                          ? const Color(0xFFF87171)
                          : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // Camera name
              TextField(
                controller: _deviceNameCtrl,
                enabled: !connecting,
                decoration: const InputDecoration(
                  labelText: 'Nombre de cámara',
                  hintText: 'phone',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),

              // Resolution selector
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(Icons.hd, color: Color(0xFF00BBDD)),
                title: const Text('Resolución al conectar'),
                trailing: Text(_resolution.label,
                    style: const TextStyle(color: Colors.white54)),
                onTap: connecting ? null : _showResolutionPicker,
              ),
              const Divider(height: 4),
              const SizedBox(height: 8),

              // QR + Go live
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: connecting ? null : _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        connecting ? null : (_cfg == null ? null : _connect),
                    icon: Icon(connecting
                        ? Icons.hourglass_top
                        : Icons.videocam),
                    label: Text(connecting ? 'Conectando...' : 'Go live'),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: connecting ? null : _manualEntry,
                icon: const Icon(Icons.keyboard),
                label: const Text('Ingresar endpoint WHIP manualmente'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Live fullscreen screen -----------------------------------------
  Widget _buildLiveView() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview
            RTCVideoView(
              _localRenderer,
              mirror: _useFrontCamera,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),

            // ON AIR badge (top-left)
            if (_isOnAir)
              Positioned(
                top: 40,
                left: 16,
                child: _onAirBadge(),
              ),

            // Status bar (top-right): latency + resolution
            Positioned(
              top: 36,
              right: 16,
              child: _statusBar(),
            ),

            // Log button (unobtrusive, top-right corner)
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.article_outlined,
                    size: 18, color: Colors.white24),
                onPressed: _showLogs,
              ),
            ),

            // Bottom controls overlay
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _controlBar(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _onAirBadge() => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
            color: Colors.red, borderRadius: BorderRadius.circular(4)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            const Text('ON AIR',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1)),
          ],
        ),
      );

  Widget _statusBar() => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                    color: Color(0xFF34D399),
                    shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(
                _latencyMs > 0 ? '${_latencyMs}ms' : 'vivo',
                style:
                    const TextStyle(color: Colors.white, fontSize: 11)),
            const SizedBox(width: 8),
            Text(_resolution.label,
                style: const TextStyle(
                    color: Colors.white54, fontSize: 11)),
          ],
        ),
      );

  Widget _controlBar() => AnimatedOpacity(
        opacity: _showControls ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ctrlBtn(
                _useFrontCamera
                    ? Icons.camera_front
                    : Icons.camera_rear,
                'Flip',
                () async {
                  final t =
                      _localStream?.getVideoTracks().firstOrNull;
                  if (t != null) {
                    try {
                      await Helper.switchCamera(t);
                    } catch (_) {}
                  }
                  setState(() => _useFrontCamera = !_useFrontCamera);
                },
              ),
              _ctrlBtn(
                _torchOn
                    ? Icons.flashlight_on
                    : Icons.flashlight_off,
                'Linterna',
                _toggleTorch,
                color: _torchOn ? Colors.yellow : Colors.white,
              ),
              _ctrlBtn(
                Icons.link_off,
                'Desconectar',
                _disconnect,
                color: Colors.red.shade400,
              ),
            ],
          ),
        ),
      );

  Widget _ctrlBtn(IconData icon, String label, VoidCallback onTap,
      {Color color = Colors.white}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  color: color.withOpacity(0.8), fontSize: 10)),
        ],
      ),
    );
  }
}

extension _FirstOrNull<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}

// ---------------------------------------------------------------------------
// QR scanner screen — ZXing C++/FFI, no ML Kit
// ---------------------------------------------------------------------------
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
      appBar:
          AppBar(title: const Text('Escaneá el QR de VortexEngine')),
      backgroundColor: Colors.black,
      body: ReaderWidget(
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
