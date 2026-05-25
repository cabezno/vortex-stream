import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/camera_service.dart';

// =============================================================================
// ConnectScreen — enter engine IP + source name, connect
// =============================================================================

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _ipCtrl   = TextEditingController(text: '192.168.1.');
  final _nameCtrl = TextEditingController(text: 'Mobile Cam 1');
  final _idCtrl   = TextEditingController(text: 'cam1');
  bool  _connecting = false;

  @override
  void initState() {
    super.initState();
    context.read<ConnectionService>().loadSaved().then((_) {
      final conn = context.read<ConnectionService>();
      if (conn.engineIp.isNotEmpty) _ipCtrl.text = conn.engineIp;
      _nameCtrl.text = conn.sourceName;
      _idCtrl.text   = conn.sourceId;
    });
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);

    final cam  = context.read<CameraService>();
    final conn = context.read<ConnectionService>();

    if (!cam.isInitialized) await cam.initialize();

    await conn.connect(
      engineIp:   _ipCtrl.text.trim(),
      sourceId:   _idCtrl.text.trim(),
      sourceName: _nameCtrl.text.trim(),
      stream:     cam.stream!,
    );

    setState(() => _connecting = false);

    if (conn.state == ConnectionState.error && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection failed: ${conn.errorMessage}'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionService>();

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
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 4),
              const Text('Connect to VortexEngine',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 40),

              // Engine IP
              _field('Engine IP Address', _ipCtrl,
                  hint: '192.168.1.100',
                  keyboard: TextInputType.number),
              const SizedBox(height: 16),

              // Source name
              _field('Camera Name', _nameCtrl, hint: 'Mobile Cam 1'),
              const SizedBox(height: 16),

              // Source ID
              _field('Source ID', _idCtrl,
                  hint: 'cam1',
                  helper: 'Must match source slot in VortexEngine'),
              const SizedBox(height: 40),

              // Connect button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00BBDD),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: (_connecting || conn.state == ConnectionState.connecting)
                      ? null : _connect,
                  child: _connecting || conn.state == ConnectionState.connecting
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                      : const Text('Connect', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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

              // Hint
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

  Widget _field(String label, TextEditingController ctrl,
      {String hint = '', TextInputType keyboard = TextInputType.text, String? helper}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 0.5)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          keyboardType: keyboard,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.white24),
            helperText: helper,
            helperStyle: const TextStyle(color: Colors.white38, fontSize: 11),
            filled: true,
            fillColor: const Color(0xFF1A1A1A),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF00BBDD))),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _nameCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }
}
