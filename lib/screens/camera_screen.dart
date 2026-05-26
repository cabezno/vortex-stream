import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/camera_service.dart';

// =============================================================================
// CameraScreen — live camera preview + controls
// Shown when connected to VortexEngine
// =============================================================================

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _renderer.initialize();
    final cam = context.read<CameraService>();
    if (cam.stream != null) _renderer.srcObject = cam.stream;

    // Allow all orientations — lock to landscape causes a rebuild mid-animation
    // where the Stack collapses because it briefly has no tight constraints.
    // The RTCVideoView + objectFitCover handles any orientation correctly.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    // Hide system bars so the video fills the full screen edge-to-edge.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _renderer.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionService>();
    final cam  = context.watch<CameraService>();

    return Scaffold(
      backgroundColor: Colors.black,
      body: OrientationBuilder(
        builder: (context, orientation) => GestureDetector(
          onTap: () => setState(() => _showControls = !_showControls),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ---- Camera preview ----
              // key forces PlatformView recreation on rotation so the Android
              // SurfaceView gets the correct landscape/portrait dimensions.
              RTCVideoView(
                _renderer,
                key: ValueKey(orientation),
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: cam.facing == CameraFacing.front,
              ),

              // ---- ON AIR indicator ----
              if (conn.isOnAir)
                Positioned(
                  top: 20,
                  left: 20,
                  child: _onAirBadge(),
                ),

              // ---- Status bar (top right) ----
              Positioned(
                top: 16,
                right: 16,
                child: _statusBar(conn),
              ),

              // ---- Controls overlay ----
              if (_showControls)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _controlBar(conn, cam),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- ON AIR badge ----
  Widget _onAirBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          const Text('ON AIR', style: TextStyle(color: Colors.white, fontSize: 12,
              fontWeight: FontWeight.w800, letterSpacing: 1)),
        ],
      ),
    );
  }

  // ---- Status bar (latency, resolution) ----
  Widget _statusBar(ConnectionService conn) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Connection dot
          Container(width: 7, height: 7,
              decoration: BoxDecoration(
                color: conn.isConnected ? const Color(0xFF00BBDD) : Colors.orange,
                shape: BoxShape.circle,
              )),
          const SizedBox(width: 6),
          Text(conn.isConnected ? '${conn.latencyMs}ms' : 'reconnecting',
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        ],
      ),
    );
  }

  // ---- Bottom control bar ----
  Widget _controlBar(ConnectionService conn, CameraService cam) {
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
            // Flip camera
            _iconBtn(Icons.flip_camera_android_rounded, 'Flip', () async {
              await cam.flipCamera();
              _renderer.srcObject = cam.stream;
            }),

            // Torch
            _iconBtn(cam.torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                cam.torchOn ? 'Torch On' : 'Torch', cam.toggleTorch,
                color: cam.torchOn ? Colors.yellow : Colors.white),

            // Resolution selector
            _resolutionBtn(cam),

            // Disconnect
            _iconBtn(Icons.link_off, 'Disconnect', () async {
              await conn.disconnect();
            }, color: Colors.red.shade400),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String label, VoidCallback onTap, {Color color = Colors.white}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color.withOpacity(0.8), fontSize: 10)),
        ],
      ),
    );
  }

  Widget _resolutionBtn(CameraService cam) {
    return GestureDetector(
      onTap: () => _showResolutionPicker(cam),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hd, color: Colors.white, size: 28),
          const SizedBox(height: 4),
          Text(cam.resolutionLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 10)),
        ],
      ),
    );
  }

  void _showResolutionPicker(CameraService cam) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: CameraResolution.values.map((r) {
            final label = switch (r) {
              CameraResolution.r720p  => '720p  (1280×720)',
              CameraResolution.r1080p => '1080p (1920×1080)',
              CameraResolution.r4k    => '4K    (3840×2160)',
            };
            return ListTile(
              title: Text(label, style: const TextStyle(color: Colors.white)),
              trailing: cam.resolution == r
                  ? const Icon(Icons.check, color: Color(0xFF00BBDD))
                  : null,
              onTap: () async {
                Navigator.pop(context);
                await cam.setResolution(r);
                _renderer.srcObject = cam.stream;
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}
