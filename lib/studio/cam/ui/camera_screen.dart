import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:samba_protocol/samba_protocol.dart';
import '../audio/vad_reporter.dart';
import '../control/control_client.dart';
import '../transport/publisher.dart';
import 'qr_scanner_sheet.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  late final WebRtcPublisher _publisher;
  late final CameraControlClient _control;
  late final VadReporter _vadReporter;

  final TextEditingController _ipController = TextEditingController(text: '192.168.1.100');
  final TextEditingController _nameController = TextEditingController(text: 'Cámara 1');
  bool _isRendererReady = false;
  CameraFacing _facing = CameraFacing.back;

  @override
  void initState() {
    super.initState();
    _publisher = WebRtcPublisher();
    // H.264 → VP8 fallback: a fresh session and offer to the switcher.
    _publisher.onRenegotiate = () async {
      if (!_control.isConnected) return;
      await _publisher.createPeerConnectionSession();
      final offer = await _publisher.createOffer();
      _control.sendMessage(OfferMessage(from: _control.peerId, to: 'switcher', sdp: offer.sdp ?? ''));
    };
    _control = CameraControlClient(
      peerId: 'cam_${DateTime.now().millisecondsSinceEpoch % 10000}',
      name: _nameController.text,
    );
    _vadReporter = VadReporter(
      getPeerConnection: () async => _publisher.peerConnection,
      onAudioLevel: (dbfs) => _control.updateAudioLevel(dbfs),
    );

    _initCamera();
    _setupControlListeners();
  }

  Future<void> _initCamera() async {
    await _localRenderer.initialize();
    final stream = await _publisher.initMediaStream(facing: _facing);
    _localRenderer.srcObject = stream;
    setState(() {
      _isRendererReady = true;
    });
  }

  void _setupControlListeners() {
    _control.onSetLayer = (msg) async {
      await _publisher.setLayer(msg.layer);
    };

    _control.onAnswer = (msg) async {
      await _publisher.setRemoteAnswer(msg.sdp);
    };

    _control.onCandidate = (msg) async {
      final cand = msg.candidate;
      await _publisher.addCandidate(RTCIceCandidate(
        cand['candidate'] as String?,
        cand['sdpMid'] as String?,
        cand['sdpMLineIndex'] as int?,
      ));
    };

    _publisher.onLocalStreamReplaced = (stream) {
      // El auto-kick re-adquirió la cámara: re-apuntar el preview al stream nuevo.
      if (!mounted) return;
      _localRenderer.srcObject = stream;
      setState(() {});
    };

    _publisher.onIceCandidate = (candidate) {
      if (_control.isConnected) {
        _control.sendMessage(IceCandidateMessage(
          from: _control.peerId,
          to: 'switcher',
          candidate: {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        ));
      }
    };
  }

  Future<void> _connect() async {
    _control.name = _nameController.text;
    await _control.connect(_ipController.text.trim());

    if (_control.isConnected) {
      await _publisher.createPeerConnectionSession();
      final offer = await _publisher.createOffer();
      _control.sendMessage(OfferMessage(
        from: _control.peerId,
        to: 'switcher',
        sdp: offer.sdp ?? '',
      ));
      _vadReporter.start();
    }
  }

  Future<void> _flipCamera() async {
    _facing = _facing == CameraFacing.back ? CameraFacing.front : CameraFacing.back;
    // Re-abre la cámara y re-cablea el sender con replaceTrack (sin renegociar):
    // el switcher recibe la nueva cámara sin cortar ni irse a negro.
    final stream = await _publisher.switchCamera(_facing);
    _localRenderer.srcObject = stream;
    setState(() {});
  }

  @override
  void dispose() {
    _vadReporter.dispose();
    _localRenderer.dispose();
    _publisher.dispose();
    _control.dispose();
    _ipController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // 1. Camera Viewport
            Center(
              child: _isRendererReady
                  ? RTCVideoView(
                      _localRenderer,
                      mirror: _facing == CameraFacing.front,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : const CircularProgressIndicator(color: Colors.redAccent),
            ),

            // 2. Top Tally & Status Bar
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: ListenableBuilder(
                listenable: _control,
                builder: (context, _) {
                  final onAir = _control.isOnAir;
                  final connected = _control.isConnected;

                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: onAir
                          ? Colors.red.withOpacity(0.9)
                          : Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: onAir ? Colors.redAccent : Colors.white24,
                        width: onAir ? 2.5 : 1.0,
                      ),
                      boxShadow: onAir
                          ? [
                              BoxShadow(
                                color: Colors.red.withOpacity(0.6),
                                blurRadius: 16,
                                spreadRadius: 4,
                              )
                            ]
                          : [],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              onAir ? Icons.sensors : Icons.sensors_off,
                              color: onAir ? Colors.white : Colors.white60,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              onAir ? '● EN EL AIRE (HD)' : '○ EN ESPERA (PREVIEW)',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: connected ? Colors.green.withOpacity(0.3) : Colors.white10,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            connected ? 'CONECTADO' : 'DESCONECTADO',
                            style: TextStyle(
                              color: connected ? Colors.greenAccent : Colors.white60,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // 3. Bottom Controls & Setup
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: ListenableBuilder(
                listenable: _control,
                builder: (context, _) {
                  if (!_control.isConnected) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E24).withOpacity(0.95),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Conectar a SAMBA Switcher',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: _ipController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'IP del Switcher',
                                    labelStyle: const TextStyle(color: Colors.white70),
                                    filled: true,
                                    fillColor: Colors.white10,
                                    suffixIcon: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.qr_code_scanner, color: Colors.redAccent, size: 22),
                                          tooltip: 'Escanear QR del Switcher',
                                          onPressed: () {
                                            QrScannerSheet.show(
                                              context,
                                              onScanned: (payload) {
                                                setState(() {
                                                  // Conservar ip:puerto del QR (no
                                                  // solo la ip) para no perder el port.
                                                  _ipController.text =
                                                      '${payload.ip}:${payload.port}';
                                                });
                                                _connect();
                                              },
                                            );
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.paste, color: Colors.white70, size: 20),
                                          tooltip: 'Pegar IP o JSON del QR',
                                          onPressed: () async {
                                            final messenger = ScaffoldMessenger.of(context);
                                            final data = await Clipboard.getData('text/plain');
                                            if (data?.text != null && data!.text!.trim().isNotEmpty) {
                                              final parsed = PairingPayload.parse(data.text!);
                                              if (mounted) {
                                                setState(() {
                                                  _ipController.text =
                                                      '${parsed.ip}:${parsed.port}';
                                                });
                                                messenger.showSnackBar(
                                                  SnackBar(content: Text('Detectado: ${parsed.ip}:${parsed.port}')),
                                                );
                                              }
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 1,
                                child: TextField(
                                  controller: _nameController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    labelText: 'Nombre',
                                    labelStyle: const TextStyle(color: Colors.white70),
                                    filled: true,
                                    fillColor: Colors.white10,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton.icon(
                              onPressed: _connect,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              icon: const Icon(Icons.link),
                              label: const Text(
                                'UNIRSE A LA SALA',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  // Connected bar
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          onPressed: _flipCamera,
                          icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                          tooltip: 'Girar cámara',
                        ),
                        Text(
                          'ID: ${_control.peerId}',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        IconButton(
                          onPressed: _control.disconnect,
                          icon: const Icon(Icons.close, color: Colors.redAccent),
                          tooltip: 'Desconectar',
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
