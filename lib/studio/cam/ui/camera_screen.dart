import 'package:flutter/material.dart';
import '../../../theme/sd_icons.dart';
import '../../../theme/samba_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:samba_protocol/samba_protocol.dart';
import '../../../services/device_capabilities.dart';
import '../../../services/nfc_pairing.dart';
import '../audio/vad_reporter.dart';
import '../control/control_client.dart';
import '../transport/publisher.dart';
import '../../common/camera_picker.dart';
import 'mic_picker.dart';
import 'qr_scanner_sheet.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  late final WebRtcPublisher _publisher;
  late final CameraControlClient _control;
  late final VadReporter _vadReporter;

  final TextEditingController _ipController = TextEditingController(text: '192.168.1.100');
  final TextEditingController _nameController = TextEditingController(text: 'Cámara 1');
  bool _isRendererReady = false;
  CameraFacing _facing = CameraFacing.back;
  MicChoice _mic = MicChoice.phone;
  /// «Solo micrófono»: this phone joins as a dedicated microphone (no video).
  bool _micOnly = false;

  Future<void> _setMicOnly(bool v) async {
    if (_control.isConnected || v == _micOnly) return;
    setState(() { _micOnly = v; _isRendererReady = false; });
    _publisher.audioOnly = v;
    _control.role = v ? PeerRole.mic : PeerRole.camera;
    final stream = await _publisher.initMediaStream(facing: _facing);
    _localRenderer.srcObject = v ? null : stream;
    if (mounted) setState(() => _isRendererReady = true);
  }
  bool _btSeen = false;

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
    _startNfc();
    WidgetsBinding.instance.addObserver(this);
    // What this phone can send (4K on air): measured once per Android build / app version.
    _publisher.onCaptureChanged = (stream) {
      if (!mounted) return;
      _localRenderer.srcObject = stream;
      setState(() {});
    };
    // A headset linked while the camera is open: offer it (one headset per presenter, plan §4).
    navigator.mediaDevices.ondevicechange = (_) async {
      final mics = await MicPicker.list();
      final bt = mics.where((m) => m.kind == MicKind.bluetooth).firstOrNull;
      if (bt == null) { _btSeen = false; if (_mic.kind == MicKind.bluetooth) _setMic(MicChoice.phone); return; }
      if (_btSeen || _mic.kind == MicKind.bluetooth || !mounted) return;
      _btSeen = true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Auricular conectado: ${bt.label}'),
        action: SnackBarAction(label: 'Usarlo como micrófono', onPressed: () => _setMic(bt)),
      ));
    };
    DeviceCapabilities.instance.ensure(cameraGranted: false).then((_) {
      _publisher.maxHeight = DeviceCapabilities.instance.maxSendHeight;
      if (_control.isConnected) _sendCamInfo();
    });
  }

  /// Join the switcher's own network by hand (Android ≤ 9 / join refused): its name and password, copy, open the
  /// Wi-Fi settings, then «Ya me conecté». True when the user says they joined.
  Future<bool> _manualWifiJoin(String ssid, String pass) async {
    const native = MethodChannel('com.vortex.vortexcam/native');
    int sdk = 0;
    try { sdk = await native.invokeMethod<int>('sdkInt') ?? 0; } catch (_) {}
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Row(children: [
          Icon(SdIcons.wifiHigh, color: Sd.cyan, size: 22),
          SizedBox(width: 10),
          Expanded(child: Text('Conectate a la red del switcher')),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(sdk > 0 && sdk < 29
              ? 'En este celular (Android ${sdk < 28 ? '8' : '9'}) la app no puede elegir la red sola: hacelo desde Ajustes.'
              : 'No se pudo conectar sola. Elegí esta red en Ajustes → Wi-Fi:', style: SdText.caption),
          const SizedBox(height: 12),
          SelectableText('Red: $ssid', style: SdText.bodyHi),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: SelectableText('Clave: $pass', style: SdText.bodyHi)),
            IconButton(
              tooltip: 'Copiar la clave',
              icon: const Icon(SdIcons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: pass));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clave copiada')));
              },
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            icon: const Icon(SdIcons.wifiHigh, size: 18),
            label: const Text('Abrir Ajustes de Wi-Fi'),
            onPressed: () => native.invokeMethod('openWifiSettings'),
          )),
          const SizedBox(height: 6),
          const Text('Cuando el celular diga «Conectado» (aunque avise «sin internet»), volvé y tocá «Ya me conecté».',
              style: SdText.caption),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: Sd.t2))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ya me conecté')),
        ],
      ),
    );
    return r == true;
  }

  /// A switcher's pairing data, from its QR or by touching it (NFC): join its own network if it has one, then the room.
  Future<void> _onPairing(PairingPayload payload) async {
    if (_control.isConnected || !mounted) return;
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
        // Android 9 and older cannot join from an app, or the user said no: guide the manual join.
        if (!mounted) return;
        final joined = await _manualWifiJoin(payload.wifiSsid!, payload.wifiPassword ?? '');
        if (!joined) return;
      }
    }
    _connect();
  }

  /// NFC on this phone: null = no NFC; enabled false = present but switched off.
  ({bool available, bool enabled})? _nfc;

  Future<void> _startNfc() async {
    final i = await NfcPairing.info();
    if (!mounted) return;
    setState(() => _nfc = i.available ? i : null);
    if (i.available && i.enabled) {
      await NfcPairing.listen((json) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Switcher detectado por NFC')));
        _onPairing(PairingPayload.parse(json));
      });
    }
  }

  /// Tells the switcher what this camera is (see CamInfoMessage).
  void _sendCamInfo() {
    _control.sendMessage(CamInfoMessage(peerId: _control.peerId, maxHeight: _publisher.maxHeight, mic: _mic.infoName));
  }

  Future<void> _setMic(MicChoice m) async {
    try {
      await MicPicker.use(m);
      if (!mounted) return;
      setState(() => _mic = m);
      if (_control.isConnected) _sendCamInfo();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo usar ${m.label}: $e')));
      }
    }
  }

  Future<void> _pickMic() async {
    final m = await MicPicker.show(context, _mic);
    if (m != null && m.id != _mic.id) await _setMic(m);
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
      await _publisher.setLayer(msg.layer, height: msg.height);
      if (mounted) setState(() {});
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
      _sendCamInfo();
      _vadReporter.start();
    }
  }

  /// Choose the camera: back / front / a USB camera or HDMI capture (CameraPicker).
  Future<void> _pickCamera() async {
    final c = await CameraPicker.show(context, currentId: _publisher.deviceId);
    if (c == null) return;
    _publisher.deviceId = c.id;
    _facing = c.facing == 'front' ? CameraFacing.front : CameraFacing.back;
    try {
      final stream = await _publisher.switchCamera(_facing);
      _localRenderer.srcObject = stream;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo abrir ${c.label}: $e')));
      }
    }
  }

  Future<void> _flipCamera() async {
    _publisher.deviceId = null;   // back to the phone's own cameras
    _facing = _facing == CameraFacing.back ? CameraFacing.front : CameraFacing.back;
    // Re-abre la cámara y re-cablea el sender con replaceTrack (sin renegociar):
    // el switcher recibe la nueva cámara sin cortar ni irse a negro.
    final stream = await _publisher.switchCamera(_facing);
    _localRenderer.srcObject = stream;
    setState(() {});
  }

  /// Back from Settings (NFC may have just been switched on): listen again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_control.isConnected) _startNfc();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NfcPairing.stopListening();
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
            if (_micOnly)
              // A dedicated microphone: a big level meter instead of the picture (talk: it must move).
              Center(child: ListenableBuilder(listenable: _control, builder: (context, _) {
                final level = ((_control.currentDbfs + 60) / 60).clamp(0.0, 1.0);
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_mic.icon, size: 56, color: level > 0.1 ? Sd.green : Sd.t3),
                  const SizedBox(height: 12),
                  Text('SOLO MICRÓFONO', style: SdText.overline.copyWith(color: Sd.t2, letterSpacing: 1.4)),
                  const SizedBox(height: 10),
                  SizedBox(width: 220, child: ClipRRect(borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(value: _control.isConnected ? level : 0, minHeight: 6,
                        backgroundColor: const Color(0x33FFFFFF),
                        valueColor: AlwaysStoppedAnimation<Color>(level > 0.8 ? Sd.amber : Sd.green)))),
                  const SizedBox(height: 6),
                  Text(_control.isConnected ? '${_control.currentDbfs.toStringAsFixed(0)} dB' : 'sin conexión',
                      style: SdText.caption),
                ]);
              }))
            else Center(
              child: _isRendererReady
                  ? RTCVideoView(
                      _localRenderer,
                      mirror: _facing == CameraFacing.front,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : const CircularProgressIndicator(strokeWidth: 1.6),
            ),

            // 2. Tally: red frame while on air, green while in preview (next to go on air)
            ListenableBuilder(
              listenable: _control,
              builder: (context, _) => (_control.isOnAir || _control.isPreview)
                  ? IgnorePointer(child: Container(decoration: BoxDecoration(
                      border: Border.all(color: Sd.wash(_control.isOnAir ? Sd.red : Sd.green, 0.85), width: 4))))
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
                  final high = _control.layer == Layer.high;
                  return Row(children: [
                    onAir
                        ? const SdPill('EN EL AIRE', color: Sd.red, icon: SdIcons.record, solid: true)
                        : _control.isPreview
                            ? const SdPill('VISTA PREVIA', color: Sd.green, icon: SdIcons.eye)
                            : const SdPill('EN ESPERA', color: Sd.t2, icon: SdIcons.circle),
                    // What this phone is sending: high only while on air / in preview / second camera of a split.
                    if (connected && !_micOnly) ...[
                      const SizedBox(width: 6),
                      SdPill(_publisher.sentHeight > 0
                          ? '${high ? 'CALIDAD ALTA' : 'CALIDAD BAJA'} · ${_publisher.sentHeight}p'
                          : (high ? 'CALIDAD ALTA' : 'CALIDAD BAJA'), color: high ? Sd.cyan : Sd.t3),
                    ],
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
                      if (!_micOnly) IconButton(
                        onPressed: _flipCamera,
                        icon: const Icon(SdIcons.cameraRotate, color: Sd.t1),
                        tooltip: 'Girar cámara',
                      ),
                      if (!_micOnly) IconButton(
                        onPressed: _pickCamera,
                        icon: Icon(SdIcons.camera, color: _publisher.deviceId != null ? Sd.cyan : Sd.t1),
                        tooltip: 'Elegir cámara (USB / HDMI)',
                      ),
                      // Microphone: which one + its live level (talk: the bar must move).
                      Expanded(child: InkWell(
                        borderRadius: BorderRadius.circular(Sd.r3),
                        onTap: _pickMic,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          child: Row(children: [
                            Icon(_mic.icon, size: 18, color: _mic.kind == MicKind.phone ? Sd.t1 : Sd.cyan),
                            const SizedBox(width: 8),
                            Flexible(child: Text(_mic.label, style: SdText.label, overflow: TextOverflow.ellipsis)),
                            const SizedBox(width: 8),
                            SizedBox(width: 48, child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: ((_control.currentDbfs + 60) / 60).clamp(0.0, 1.0), minHeight: 3,
                                backgroundColor: const Color(0x33FFFFFF),
                                valueColor: const AlwaysStoppedAnimation<Color>(Sd.green),
                              ),
                            )),
                            const SizedBox(width: 4),
                            const Icon(SdIcons.caretDown, size: 14, color: Sd.t2),
                          ]),
                        ),
                      )),
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
      if (_nfc != null) ...[
        const SizedBox(height: 6),
        InkWell(
          onTap: _nfc!.enabled ? null : () async { await NfcPairing.openSettings(); },
          child: Row(children: [
            Icon(SdIcons.contactlessPayment, size: 16, color: _nfc!.enabled ? Sd.cyan : Sd.t3),
            const SizedBox(width: 6),
            Flexible(child: Text(_nfc!.enabled
                ? 'O acercá este celular al switcher (por la parte de atrás).'
                : 'NFC apagado: tocá para activarlo y emparejar acercando los celulares.',
                style: SdText.caption.copyWith(color: _nfc!.enabled ? Sd.cyan : Sd.t2))),
          ]),
        ),
      ],
      const SizedBox(height: 6),
      SwitchListTile(
        contentPadding: EdgeInsets.zero, dense: true,
        title: const Text('Solo micrófono', style: SdText.bodyHi),
        subtitle: const Text('Este celular capta la voz de un presentador, sin video. En el switcher se elige a qué '
            'cámara corta cuando habla.', style: SdText.caption),
        value: _micOnly,
        onChanged: _setMicOnly,
      ),
      const SizedBox(height: 8),
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
                    QrScannerSheet.show(context, onScanned: _onPairing);
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
