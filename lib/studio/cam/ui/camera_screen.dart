import 'package:flutter/material.dart';
import '../../../theme/sd_icons.dart';
import '../../../theme/samba_theme.dart';
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
      backgroundColor: Sd.void_,
      body: SafeArea(
        child: Stack(
          children: [
            // 1. Camera viewport
            // Center, NOT Positioned.fill: with the preview stretched to the whole Stack the engine stops producing
            // frames on the Galaxy A10 and the Mi A3 (screen fully black, everything NEEDS-PAINT, no error) — 2026-10-05.
            Center(
              child: _isRendererReady
                  ? RTCVideoView(
                      _localRenderer,
                      mirror: _facing == CameraFacing.front,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : const CircularProgressIndicator(strokeWidth: 1.6),
            ),

            // 2. Tally: a soft red frame while on air
            ListenableBuilder(
              listenable: _control,
              builder: (context, _) => _control.isOnAir
                  ? IgnorePointer(child: Container(decoration: BoxDecoration(
                      border: Border.all(color: Sd.wash(Sd.red, 0.85), width: 4))))
                  : const SizedBox.shrink(),
            ),

            // 3. Status pills
            Positioned(
              top: 14, left: 16, right: 16,
              child: ListenableBuilder(
                listenable: _control,
                builder: (context, _) {
                  final onAir = _control.isOnAir;
                  final connected = _control.isConnected;
                  return Row(children: [
                    onAir
                        ? const SdPill('EN EL AIRE', color: Sd.red, icon: SdIcons.record, solid: true)
                        : const SdPill('EN ESPERA', color: Sd.t2, icon: SdIcons.circle),
                    const Spacer(),
                    connected
                        ? const SdPill('CONECTADO', color: Sd.green, icon: SdIcons.plugsConnected)
                        : const SdPill('SIN CONEXIÓN', color: Sd.t3, icon: SdIcons.plugs),
                  ]);
                },
              ),
            ),

            // 4. Bottom: join card / connected bar
            Positioned(
              bottom: 16, left: 16, right: 16,
              child: ListenableBuilder(
                listenable: _control,
                builder: (context, _) {
                  if (!_control.isConnected) return _joinCard(context);
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xCC000000),
                      borderRadius: BorderRadius.circular(Sd.r3),
                      border: Border.all(color: Sd.borderStrong),
                    ),
                    child: Row(children: [
                      IconButton(
                        onPressed: _flipCamera,
                        icon: const Icon(SdIcons.cameraRotate, color: Sd.t1),
                        tooltip: 'Girar cámara',
                      ),
                      Expanded(child: Text(_control.peerId, textAlign: TextAlign.center,
                          style: SdText.label, overflow: TextOverflow.ellipsis)),
                      IconButton(
                        onPressed: _control.disconnect,
                        icon: const Icon(SdIcons.x, color: Sd.red),
                        tooltip: 'Salir de la sala',
                      ),
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _joinCard(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
    decoration: BoxDecoration(
      color: const Color(0xF2111111),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Sd.borderStrong),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('SWITCHER', style: SdText.overline.copyWith(color: Sd.magenta, letterSpacing: 1.6)),
      const SizedBox(height: 4),
      const Text('Unirse a un switcher', style: SdText.heading),
      const SizedBox(height: 2),
      const Text('Escaneá su QR o escribí su IP.', style: SdText.caption),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          flex: 2,
          child: TextField(
            controller: _ipController,
            style: SdText.bodyHi,
            decoration: InputDecoration(
              labelText: 'IP del switcher',
              suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: const Icon(SdIcons.qrCode, color: Sd.magenta, size: 22),
                  tooltip: 'Escanear el QR del switcher',
                  onPressed: () {
                    QrScannerSheet.show(context, onScanned: (payload) async {
                      // Keep ip:port from the QR (not just the ip) so the port is not lost.
                      setState(() => _ipController.text = '${payload.ip}:${payload.port}');
                      if (payload.hasWifi) {
                        // The switcher made its own network: join it first (Android shows its confirmation once).
                        final messenger = ScaffoldMessenger.of(context);
                        messenger.showSnackBar(SnackBar(content: Text('Uniéndose a la red del switcher «${payload.wifiSsid}»…')));
                        bool ok = false;
                        try {
                          ok = await const MethodChannel('com.vortex.vortexcam/native').invokeMethod<bool>('connectWifi',
                              {'ssid': payload.wifiSsid, 'password': payload.wifiPassword ?? ''}) ?? false;
                        } catch (_) {}
                        if (!ok) {
                          messenger.showSnackBar(const SnackBar(content: Text(
                              'No se pudo unir a la red del switcher. Conectate a mano desde Ajustes → Wi-Fi y volvé a intentar.')));
                          return;
                        }
                      }
                      _connect();
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(SdIcons.clipboardText, size: 20),
                  tooltip: 'Pegar la IP o el JSON del QR',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final data = await Clipboard.getData('text/plain');
                    if (data?.text != null && data!.text!.trim().isNotEmpty) {
                      final parsed = PairingPayload.parse(data.text!);
                      if (mounted) {
                        setState(() => _ipController.text = '${parsed.ip}:${parsed.port}');
                        messenger.showSnackBar(SnackBar(content: Text('Detectado: ${parsed.ip}:${parsed.port}')));
                      }
                    }
                  },
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _nameController,
            style: SdText.bodyHi,
            decoration: const InputDecoration(labelText: 'Nombre'),
          ),
        ),
      ]),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _connect,
          style: FilledButton.styleFrom(backgroundColor: Sd.magenta),
          icon: const Icon(SdIcons.link, size: 20),
          label: const Text('Unirse a la sala'),
        ),
      ),
    ]),
  );
}
