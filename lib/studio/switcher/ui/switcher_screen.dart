import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../encode/program_encoder.dart';
import '../local/local_camera.dart';
import '../mixer/program_mixer.dart';
import '../output/recorder.dart';
import '../output/rtmp_out.dart';
import '../room/room_host.dart';
import '../switch/director.dart';
import '../transport/subscriber.dart';
import 'program_layout_view.dart';

class SwitcherScreen extends StatefulWidget {
  const SwitcherScreen({super.key});

  @override
  State<SwitcherScreen> createState() => _SwitcherScreenState();
}

class _SwitcherScreenState extends State<SwitcherScreen> {
  late final RoomHost _roomHost;
  late final Director _director;
  late final WebRtcSubscriber _subscriber;
  late final ProgramEncoder _encoder;
  late final RtmpOut _rtmpOut;
  late final ProgramRecorder _recorder;
  late final ProgramMixer _mixer;
  late final LocalCameraSource _localCam;
  String _localIp = '127.0.0.1';

  @override
  void initState() {
    super.initState();
    _roomHost = RoomHost(port: 8088);
    _subscriber = WebRtcSubscriber(roomHost: _roomHost);
    _director = Director(roomHost: _roomHost, subscriber: _subscriber);
    _encoder = ProgramEncoder();
    _rtmpOut = RtmpOut(encoder: _encoder);
    _recorder = ProgramRecorder(encoder: _encoder);
    _mixer = ProgramMixer(roomHost: _roomHost, encoder: _encoder);
    _localCam = LocalCameraSource(roomHost: _roomHost);

    _mixer.addListener(_syncNativeCameraSources);
    _director.addListener(_syncNativeCameraSources);
    _subscriber.addListener(_syncNativeCameraSources);

    _detectLocalIp();
    _roomHost.start().then((_) {
      setState(() {});
    });
  }

  // DIAGNÓSTICO 2026-09-29: el encoder nativo (pipeline RTMP/compositor a medio
  // hacer) refleja dentro de flutter_webrtc por textureId para agarrar el
  // videoTrack del renderer. Eso COMPITE con el RTCVideoView de Flutter por la
  // misma textura → el decoder VP8 se traba tras 1 frame y congela todo el flujo
  // (y por RTCP frena la cámara). Se desactiva para que el preview en vivo del
  // switcher funcione. Reactivar SOLO cuando el puente WebRTC→GL nativo esté hecho.
  // 2026-10-04 (Samba Air): RE-ENABLED. The encoder made its EGL context (shared with libwebrtc) current on the main
  // thread at start and never released it, so its render thread failed every frame — most likely the same root of
  // the "freeze after 1 frame". Fixed in HardwareProgramEncoder (detachCurrent); without this the encoded program
  // (RTMP / SD) carried NO camera, only the background. If the freeze ever comes back, set this to false again.
  static const bool _kEnableNativeEncoderSources = true;

  void _syncNativeCameraSources() {
    if (!_kEnableNativeEncoderSources) return;
    final primaryPeerId = _mixer.primaryPeerId ?? _director.activePeerId;
    final secondaryPeerId = _mixer.secondaryPeerId;
    final primaryRenderer = primaryPeerId != null ? _subscriber.getRenderer(primaryPeerId) : null;
    final secondaryRenderer = secondaryPeerId != null ? _subscriber.getRenderer(secondaryPeerId) : null;
    _encoder.setCameraSources(
      primaryTextureId: primaryRenderer?.textureId,
      secondaryTextureId: secondaryRenderer?.textureId,
    );
  }

  Future<void> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      String? wlan, home, priv, any;
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (addr.isLoopback || ip.startsWith('169.254.')) continue;
          any ??= ip;
          if (name.startsWith('wlan') || name.startsWith('wl')) wlan ??= ip;
          if (ip.startsWith('192.168.')) home ??= ip;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
            priv ??= ip;
          }
        }
      }
      // Preferir la interfaz Wi-Fi (wlan) > rango casero 192.168.x > cualquier
      // privada > cualquiera. Evita agarrar la IP del VPN/datos móviles (10.x).
      final chosen = wlan ?? home ?? priv ?? any ?? '127.0.0.1';
      debugPrint('[IP] interfaces=${interfaces.map((i) => "${i.name}:${i.addresses.map((a) => a.address).join(",")}").join(" | ")}');
      debugPrint('[IP] elegida=$chosen (wlan=$wlan home=$home priv=$priv any=$any)');
      if (mounted) setState(() => _localIp = chosen);
    } catch (e) {
      debugPrint('[IP] error detectando IP: $e');
    }
  }

  void _showQrPairingDialog() {
    // Refrescar la IP por si al arrancar la WiFi no estaba lista.
    _detectLocalIp();
    final connectionPayload = '{"ip":"$_localIp","port":8088,"room":"samba_studio"}';
    debugPrint('[QR] payload=$connectionPayload');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E26),
        title: const Text('Emparejar Cámara (QR)', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: connectionPayload,
                version: QrVersions.auto,
                size: 200.0,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'IP del Switcher: $_localIp',
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 4),
            const Text(
              'Puerto: 8088',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CERRAR', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _showAudioSettingsDialog() {
    final cfg = _director.config;
    showDialog(
      context: context,
      builder: (ctx) {
        double threshold = cfg.thresholdDbfs;
        double onset = cfg.onsetMs;
        double hold = cfg.holdSec;
        double silence = cfg.silenceSec;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E26),
              title: const Row(
                children: [
                  Icon(Icons.tune, color: Colors.amberAccent),
                  SizedBox(width: 8),
                  Text('Ajustes del Audio Switcher', style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Threshold
                    Text('Umbral de Voz: ${threshold.toStringAsFixed(0)} dBFS', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    Slider(
                      value: threshold,
                      min: -60.0,
                      max: -10.0,
                      divisions: 50,
                      activeColor: Colors.amberAccent,
                      onChanged: (val) {
                        setModalState(() => threshold = val);
                        _director.updateConfig(thresholdDbfs: val);
                      },
                    ),
                    const SizedBox(height: 8),

                    // Onset
                    Text('Onset Mínimo: ${onset.toStringAsFixed(0)} ms', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    Slider(
                      value: onset,
                      min: 20.0,
                      max: 300.0,
                      divisions: 28,
                      activeColor: Colors.amberAccent,
                      onChanged: (val) {
                        setModalState(() => onset = val);
                        _director.updateConfig(onsetMs: val);
                      },
                    ),
                    const SizedBox(height: 8),

                    // Hold time (anti-chatter)
                    Text('Retención (Anti-Chatter): ${hold.toStringAsFixed(1)} s', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    Slider(
                      value: hold,
                      min: 0.5,
                      max: 4.0,
                      divisions: 35,
                      activeColor: Colors.amberAccent,
                      onChanged: (val) {
                        setModalState(() => hold = val);
                        _director.updateConfig(holdSec: val);
                      },
                    ),
                    const SizedBox(height: 8),

                    // Silence delay
                    Text('Tiempo para Silencio: ${silence.toStringAsFixed(1)} s', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    Slider(
                      value: silence,
                      min: 1.0,
                      max: 6.0,
                      divisions: 25,
                      activeColor: Colors.amberAccent,
                      onChanged: (val) {
                        setModalState(() => silence = val);
                        _director.updateConfig(silenceSec: val);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('LISTO', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRtmpConfigDialog() {
    final urlCtrl = TextEditingController(text: _rtmpOut.rtmpUrl);
    final keyCtrl = TextEditingController(text: _rtmpOut.streamKey);
    bool abr = _rtmpOut.abrEnabled;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModal) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E26),
          title: const Row(
            children: [
              Icon(Icons.cell_tower, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('Emisión RTMP (En Vivo)', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'URL del Servidor RTMP',
                  labelStyle: TextStyle(color: Colors.white70),
                  helperText: 'SAMBA (PC en la LAN): rtmp://IP-DEL-PC:1935/live · cualquier clave · '
                      'YouTube: rtmps://a.rtmps.youtube.com/live2 · Facebook: rtmps://live-api-s.facebook.com:443/rtmp/ · '
                      'Twitch: rtmp://live.twitch.tv/app',
                  helperStyle: TextStyle(color: Colors.white38, fontSize: 10),
                  helperMaxLines: 4,
                  filled: true,
                  fillColor: Colors.white10,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Clave de Transmisión (Stream Key)',
                  labelStyle: TextStyle(color: Colors.white70),
                  filled: true,
                  fillColor: Colors.white10,
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('ABR para 5G/Móvil', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Ajuste dinámico según saturación de red', style: TextStyle(color: Colors.white54, fontSize: 11)),
                value: abr,
                activeColor: Colors.redAccent,
                onChanged: (val) => setModal(() => abr = val),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCELAR', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: () async {
                _rtmpOut.configure(url: urlCtrl.text.trim(), streamKey: keyCtrl.text.trim(), abrEnabled: abr);
                Navigator.pop(ctx);
                await _rtmpOut.startStream();
                if (!mounted) return;
                if (_rtmpOut.state == RtmpState.error) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    backgroundColor: Colors.red.shade900,
                    duration: const Duration(seconds: 8),
                    content: Text('No se pudo salir en vivo: ${_rtmpOut.errorMessage}'),
                  ));
                } else if (_rtmpOut.isStreaming) {
                  // Tell the user if the program goes out without sound (mic permission denied / busy).
                  Future.delayed(const Duration(seconds: 3), () {
                    if (mounted && _rtmpOut.isStreaming && !_rtmpOut.hasAudio) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('En vivo SIN AUDIO: no hay permiso o acceso al micrófono de este celular.'),
                      ));
                    }
                  });
                }
              },
              child: const Text('INICIAR EN VIVO'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleRecording() async {
    if (_recorder.isRecording) {
      final path = await _recorder.stopRecording();
      if (mounted && path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Grabación guardada en: $path')),
        );
      }
    } else {
      await _recorder.startRecording();
    }
  }

  Future<void> _toggleLocalCamera() async {
    try {
      if (_localCam.isActive) {
        await _localCam.stop();
      } else {
        await _localCam.start();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo abrir la cámara local: $e')),
        );
      }
    }
  }

  Widget _buildLayoutChip(String label, LayoutMode mode) {
    final isSelected = _mixer.mode == mode;
    return GestureDetector(
      onTap: () => _mixer.setLayoutMode(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? Colors.amberAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white70,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _mixer.removeListener(_syncNativeCameraSources);
    _director.removeListener(_syncNativeCameraSources);
    _subscriber.removeListener(_syncNativeCameraSources);

    _localCam.dispose();
    _mixer.dispose();
    _rtmpOut.dispose();
    _recorder.dispose();
    _encoder.dispose();
    _subscriber.dispose();
    _director.dispose();
    _roomHost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF18181F),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.redAccent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'SAMBA',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Flexible(
              child: Text(
                'Móvil Studio',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                ':8088',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
          ],
        ),
        actions: [
          // Local Camera (cámara del propio switcher como fuente)
          ListenableBuilder(
            listenable: _localCam,
            builder: (context, _) {
              final on = _localCam.isActive;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      on ? Icons.videocam : Icons.videocam_off_outlined,
                      color: on ? Colors.greenAccent : Colors.white70,
                    ),
                    tooltip: on ? 'Apagar cámara local' : 'Usar cámara local como fuente',
                    onPressed: _toggleLocalCamera,
                  ),
                  if (on)
                    IconButton(
                      icon: const Icon(Icons.flip_camera_ios, color: Colors.white70),
                      tooltip: 'Girar cámara local',
                      onPressed: () => _localCam.flip(),
                    ),
                ],
              );
            },
          ),
          // QR Pairing Button
          IconButton(
            icon: const Icon(Icons.qr_code_2, color: Colors.white70),
            tooltip: 'Emparejar Cámara (QR)',
            onPressed: _showQrPairingDialog,
          ),
          // Audio Switcher Settings Button
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.white70),
            tooltip: 'Ajustes Audio Switcher',
            onPressed: _showAudioSettingsDialog,
          ),
          // Auto Switcher Toggle Button
          ListenableBuilder(
            listenable: _director,
            builder: (context, _) {
              final isAuto = _director.isAutoSwitch;
              return FilterChip(
                avatar: Icon(
                  Icons.auto_mode,
                  size: 16,
                  color: isAuto ? Colors.black : Colors.white70,
                ),
                label: Text(
                  isAuto ? 'AUTO' : 'MANUAL',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                    color: isAuto ? Colors.black : Colors.white,
                  ),
                ),
                selected: isAuto,
                selectedColor: Colors.amberAccent,
                backgroundColor: Colors.white12,
                onSelected: (val) => _director.toggleAutoSwitch(val),
              );
            },
          ),
          const SizedBox(width: 4),
          // Record SD Button
          ListenableBuilder(
            listenable: _recorder,
            builder: (context, _) {
              final isRec = _recorder.isRecording;
              return IconButton(
                icon: Icon(
                  isRec ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: isRec ? Colors.amberAccent : Colors.white70,
                ),
                tooltip: isRec ? 'Detener Grabación SD' : 'Grabar a SD',
                onPressed: _toggleRecording,
              );
            },
          ),
          // RTMP Broadcast Button
          ListenableBuilder(
            listenable: _rtmpOut,
            builder: (context, _) {
              final isLive = _rtmpOut.isStreaming;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isLive ? Colors.red : Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: Icon(isLive ? Icons.sensors : Icons.cell_tower, size: 16),
                  label: Text(
                    isLive ? 'LIVE' : 'EMITIR',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  ),
                  onPressed: isLive ? _rtmpOut.stopStream : _showRtmpConfigDialog,
                ),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_roomHost, _subscriber, _rtmpOut, _recorder, _encoder, _mixer, _localCam]),
        builder: (context, _) {
          final cameras = _roomHost.cameras;
          final activePeerId = _roomHost.activePeerId;

          return Column(
            children: [
              // 1. Program Monitor Viewport
              Expanded(
                flex: 4,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: activePeerId != null ? Colors.redAccent : Colors.white24,
                      width: 2.0,
                    ),
                    boxShadow: activePeerId != null
                        ? [
                            BoxShadow(
                              color: Colors.redAccent.withOpacity(0.3),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ]
                        : [],
                  ),
                  child: Stack(
                    children: [
                      // Program Composed Viewport (Single, Split-Screen 50/50, PiP)
                      Positioned.fill(
                        child: ProgramLayoutView(
                          mixer: _mixer,
                          subscriber: _subscriber,
                          cameras: cameras,
                          localRenderer: _localCam.isActive ? _localCam.renderer : null,
                          localPeerId: _localCam.peerId,
                        ),
                      ),

                      // Program Status Badges Row
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'PROGRAM',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                if (_rtmpOut.isStreaming) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: _rtmpOut.reconnecting ? Colors.orange.shade900 : Colors.red.shade900,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: _rtmpOut.reconnecting ? Colors.orangeAccent : Colors.redAccent),
                                    ),
                                    child: Text(
                                      _rtmpOut.reconnecting
                                          ? '● RECONECTANDO…'
                                          : '● LIVE (${_rtmpOut.currentBitrateKbps} kbps${_rtmpOut.hasAudio ? '' : ' · SIN AUDIO'})',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                                if (_recorder.isRecording) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.shade900,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: Colors.amberAccent),
                                    ),
                                    child: Text(
                                      '● REC (${_recorder.fileSizeMb.toStringAsFixed(1)} MB)',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Text(
                                '${_encoder.width}x${_encoder.height}p @ ${_encoder.fps}fps',
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Layout Mode Floating Selector (Single, Split-Screen 50/50, PiP)
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 12,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildLayoutChip('1 CAM', LayoutMode.single),
                                  const SizedBox(width: 4),
                                  _buildLayoutChip('SPLIT 50/50', LayoutMode.splitScreen),
                                  const SizedBox(width: 4),
                                  _buildLayoutChip('PiP', LayoutMode.pip),
                                ],
                              ),
                            ),
                            if (_mixer.mode != LayoutMode.single && cameras.length > 1)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.8),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.amberAccent.withOpacity(0.5)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: _mixer.secondaryPeerId ??
                                        cameras.firstWhere((c) => c.id != _mixer.primaryPeerId, orElse: () => cameras.first).id,
                                    dropdownColor: const Color(0xFF1E1E26),
                                    style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                    icon: const Icon(Icons.arrow_drop_down, color: Colors.amberAccent, size: 16),
                                    items: cameras
                                        .where((c) => c.id != _mixer.primaryPeerId)
                                        .map((c) => DropdownMenuItem(value: c.id, child: Text('Cam 2: ${c.name}')))
                                        .toList(),
                                    onChanged: (val) => _mixer.setSecondary(val),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 2. Multiview Grid Title
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'MULTIVIEW (${cameras.length} Cámaras)',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.0,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Text(
                      '1 Decode + N Low',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              // 3. Multiview Camera Cards Grid
              Expanded(
                flex: 3,
                child: cameras.isEmpty
                    ? Center(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: QrImageView(
                                  data: '{"ip":"$_localIp","port":8088,"room":"samba_studio"}',
                                  version: QrVersions.auto,
                                  size: 160.0,
                                  errorStateBuilder: (ctx, err) => const SizedBox(
                                    width: 160,
                                    height: 160,
                                    child: Center(
                                      child: Text('QR\nno disponible',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.black54)),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Escaneá este QR con SAMBA Cam',
                                style: TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'o conectá manual a   $_localIp:8088',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15),
                              ),
                              const SizedBox(height: 16),
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white24),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Esperando cámaras en la red local...',
                                style: TextStyle(color: Colors.white38, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1.6,
                        ),
                        itemCount: cameras.length,
                        itemBuilder: (context, idx) {
                          final cam = cameras[idx];
                          final isActive = cam.id == activePeerId;
                          // La cámara local del switcher usa su renderer local
                          // (captura local); las remotas, el del subscriber.
                          final isLocal = cam.id == _localCam.peerId;
                          final camRenderer = isLocal
                              ? _localCam.renderer
                              : _subscriber.getRenderer(cam.id);
                          final hasVideo = camRenderer != null && camRenderer.srcObject != null;

                          return GestureDetector(
                            onTap: () => _director.manualCut(cam.id),
                            child: Container(
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E1E26),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isActive ? Colors.redAccent : Colors.white24,
                                  width: isActive ? 2.5 : 1.0,
                                ),
                              ),
                              child: Stack(
                                children: [
                                  // Background live video preview
                                  if (hasVideo)
                                    Positioned.fill(
                                      child: RTCVideoView(
                                        camRenderer,
                                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                                      ),
                                    ),
                                  // Dark gradient overlay for UI readability
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [
                                            Colors.black.withOpacity(hasVideo ? 0.7 : 0.0),
                                            Colors.black.withOpacity(hasVideo ? 0.85 : 0.0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Card Content
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              cam.name,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isActive ? Colors.red : Colors.white12,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          isActive ? 'EN EL AIRE' : 'PREVIEW',
                                          style: TextStyle(
                                            color: isActive ? Colors.white : Colors.white70,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),

                                  // Audio dBFS meter
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Audio RMS',
                                            style: TextStyle(color: Colors.white54, fontSize: 10),
                                          ),
                                          Text(
                                            '${cam.lastAudioDbfs.toStringAsFixed(1)} dBFS',
                                            style: const TextStyle(color: Colors.white70, fontSize: 10),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: LinearProgressIndicator(
                                          value: ((cam.lastAudioDbfs + 60.0) / 60.0).clamp(0.0, 1.0),
                                          backgroundColor: Colors.white12,
                                          valueColor: AlwaysStoppedAnimation<Color>(
                                            cam.lastAudioDbfs > -20.0
                                                ? Colors.amberAccent
                                                : Colors.greenAccent,
                                          ),
                                          minHeight: 6,
                                        ),
                                      ),
                                    ],
                                  ),

                                  // Cut Action Button
                                  SizedBox(
                                    width: double.infinity,
                                    height: 28,
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isActive ? Colors.redAccent : Colors.white10,
                                        foregroundColor: Colors.white,
                                        padding: EdgeInsets.zero,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                      ),
                                      onPressed: () => _director.manualCut(cam.id),
                                      child: Text(
                                        isActive ? 'CÁMARA ACTIVA' : 'CORTAR A ESTA CÁMARA',
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                      ),
              ),

              // 4. Log History Footer
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                color: const Color(0xFF14141A),
                child: ListenableBuilder(
                  listenable: _director,
                  builder: (context, _) {
                    final lastLog = _director.switchHistory.firstOrNull ?? 'Listo para conmutar';
                    return Row(
                      children: [
                        const Icon(Icons.history, size: 16, color: Colors.white54),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            lastLog,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
