import 'dart:convert';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/srt_connection_service.dart';
import '../services/camera_service.dart';

// =============================================================================
// ConnectScreen — scan pairing QR or enter engine IP manually, then connect
// =============================================================================

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _ipCtrl    = TextEditingController(text: '192.168.137.1'); // hotspot default
  final _portCtrl  = TextEditingController(text: '8080');
  final _srtPortCtrl = TextEditingController(text: '9000');
  final _nameCtrl  = TextEditingController(text: 'Mobile Cam 1');
  final _idCtrl    = TextEditingController(text: 'cam1');
  bool  _connecting = false;
  String _transport = 'srt';  // 'srt' | 'whip'

  @override
  void initState() {
    super.initState();
    context.read<ConnectionService>().loadSaved().then((_) {
      if (!mounted) return;
      final conn = context.read<ConnectionService>();
      if (conn.engineIp.isNotEmpty) _ipCtrl.text = conn.engineIp;
      _portCtrl.text = conn.enginePort.toString();
      _nameCtrl.text = conn.sourceName;
      _idCtrl.text   = conn.sourceId;
    });
  }

  // ---------------------------------------------------------------------------
  // QR scan
  // ---------------------------------------------------------------------------
  Future<void> _scanQR() async {
    final granted = await Permission.camera.request();
    if (!granted.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Camera permission required to scan QR')));
      }
      return;
    }
    if (!mounted) return;

    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _QRScanPage()),
    );
    if (raw == null || raw.isEmpty) return;

    // Parse VortexCam pairing payload:
    // {"app":"vortexcam","host":"...","whip":{"url":"http://ip:8080/whip/"},"video":{...}}
    try {
      final j = jsonDecode(raw);
      if (j is Map && j['app'] == 'vortexcam') {
        final whipUrl = (j['whip'] as Map?)?['url']?.toString() ?? '';
        // Extract IP from URL (http://ip:port/...)
        final uri = Uri.tryParse(whipUrl);
        if (uri != null && uri.host.isNotEmpty) {
          setState(() {
            _ipCtrl.text   = uri.host;
            if (uri.port != 0) _portCtrl.text = uri.port.toString();
          });
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Paired with ${j['host'] ?? 'VortexEngine'}')));
        }
        return;
      }
    } catch (_) {}

    // Fallback: treat raw text as a plain IP or http URL
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.isNotEmpty) {
      setState(() {
        _ipCtrl.text = uri.host;
        if (uri.port != 0) _portCtrl.text = uri.port.toString();
      });
    } else if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(raw.trim())) {
      setState(() => _ipCtrl.text = raw.trim());
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('QR not recognised as a VortexCam code')));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Connect
  // ---------------------------------------------------------------------------
  Future<void> _connect() async {
    setState(() => _connecting = true);

    final cam = context.read<CameraService>();
    if (!cam.isInitialized) await cam.initialize();

    if (_transport == 'srt') {
      // SRT transport — H.265 HW, LAN-optimized
      final srt = context.read<SrtConnectionService>();
      srt.configure(width: 1280, height: 720, targetBitrateBps: 6000000, srtLatencyMs: 80);
      await srt.connectTo(
        _ipCtrl.text.trim(),
        port: int.tryParse(_srtPortCtrl.text.trim()) ?? 9000,
      );
      setState(() => _connecting = false);
      if (srt.state == SrtState.error && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('SRT connection failed: ${srt.errorMsg}'),
          backgroundColor: Colors.red.shade800,
        ));
      }
    } else {
      // WHIP/WebRTC transport — H.264, works over internet
      final conn = context.read<ConnectionService>();
      await conn.connect(
        engineIp:      _ipCtrl.text.trim(),
        enginePort:    int.tryParse(_portCtrl.text.trim()) ?? 8080,
        sourceId:      _idCtrl.text.trim(),
        sourceName:    _nameCtrl.text.trim(),
        stream:        cam.stream!,
        cameraService: cam,
      );
      setState(() => _connecting = false);
      if (conn.state == ConnectionState.error && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('WHIP connection failed: ${conn.errorMessage}'),
          backgroundColor: Colors.red.shade800,
        ));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionService>();
    final busy = _connecting || conn.state == ConnectionState.connecting;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(children: [
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00BBDD), shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                const Text('VortexCam',
                    style: TextStyle(color: Colors.white, fontSize: 22,
                        fontWeight: FontWeight.w600)),
                const Spacer(),
                // QR scan button
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00BBDD),
                    side: const BorderSide(color: Color(0xFF00BBDD)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onPressed: busy ? null : _scanQR,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Scan QR', style: TextStyle(fontSize: 13)),
                ),
              ]),
              const SizedBox(height: 4),
              const Text('Connect to VortexEngine',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 32),

              // Transport selector
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(children: [
                  _transportBtn('SRT', 'srt',
                      subtitle: 'H.265 · LAN · ≤100ms'),
                  _transportBtn('WHIP', 'whip',
                      subtitle: 'H.264 · Internet / LAN'),
                ]),
              ),
              const SizedBox(height: 16),

              if (_transport == 'srt') ...[
                // SRT: show discover button + IP
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: _field('Engine IP (hotspot: 192.168.137.1)', _ipCtrl,
                        hint: '192.168.137.1',
                        keyboard: TextInputType.number),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: _field('SRT Port', _srtPortCtrl,
                        hint: '9000',
                        keyboard: TextInputType.number),
                  ),
                ]),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00BBDD),
                    side: const BorderSide(color: Color(0xFF00BBDD)),
                  ),
                  onPressed: busy ? null : () async {
                    final srt = context.read<SrtConnectionService>();
                    await srt.discoverAndConnect(
                        fallbackIp: _ipCtrl.text.trim(),
                        fallbackPort: int.tryParse(_srtPortCtrl.text.trim()) ?? 9000);
                  },
                  icon: const Icon(Icons.wifi_find, size: 16),
                  label: const Text('Auto-discover engine (mDNS)',
                      style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(height: 24),
              ],

              if (_transport == 'whip') ...[
              Row(children: [
                Expanded(
                  flex: 3,
                  child: _field('Engine IP Address', _ipCtrl,
                      hint: '192.168.1.100',
                      keyboard: TextInputType.number),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 1,
                  child: _field('Port', _portCtrl,
                      hint: '8080',
                      keyboard: TextInputType.number),
                ),
              ]),
              const SizedBox(height: 16),

              _field('Camera Name', _nameCtrl, hint: 'Mobile Cam 1'),
              const SizedBox(height: 16),

              _field('Source ID', _idCtrl,
                  hint: 'cam1',
                  helper: 'Must match source slot in VortexEngine'),
              const SizedBox(height: 24),
              ], // end if (_transport == 'whip')

              const SizedBox(height: 8),

              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00BBDD),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: busy ? null : _connect,
                  child: busy
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.black))
                      : const Text('Connect',
                          style: TextStyle(fontSize: 16,
                              fontWeight: FontWeight.w600)),
                ),
              ),

              if (conn.state == ConnectionState.error) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(conn.errorMessage,
                      style: const TextStyle(color: Colors.red, fontSize: 12)),
                ),
              ],

              const Spacer(),
              const Center(
                child: Text(
                  'Make sure VortexEngine is running on the same network',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white24, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _transportBtn(String label, String value, {String subtitle = ''}) {
    final selected = _transport == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _transport = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF00BBDD) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            children: [
              Text(label, textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white60,
                    fontWeight: FontWeight.w600, fontSize: 14,
                  )),
              if (subtitle.isNotEmpty)
                Text(subtitle, textAlign: TextAlign.center,
                    style: TextStyle(
                      color: selected ? Colors.black87 : Colors.white30,
                      fontSize: 10,
                    )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
      {String hint = '', TextInputType keyboard = TextInputType.text,
      String? helper}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Colors.white70, fontSize: 12, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          keyboardType: keyboard,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white24),
            helperText: helper,
            helperStyle:
                const TextStyle(color: Colors.white38, fontSize: 11),
            filled: true,
            fillColor: const Color(0xFF1A1A1A),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    const BorderSide(color: Color(0xFF00BBDD))),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _nameCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }
}

// =============================================================================
// QR scanner screen — uses flutter_zxing (ZXing C++ via FFI, no ML Kit)
// =============================================================================
class _QRScanPage extends StatefulWidget {
  const _QRScanPage();
  @override
  State<_QRScanPage> createState() => _QRScanPageState();
}

class _QRScanPageState extends State<_QRScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan VortexEngine QR'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
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
