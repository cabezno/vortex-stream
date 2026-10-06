import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:samba_protocol/samba_protocol.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../theme/sd_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../theme/samba_theme.dart';
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

  // The switcher's own Wi-Fi network for its cameras (plan §1): one hop instead of two through a router, no foreign
  // traffic, the SIM free for the outgoing stream. Credentials travel in the QR. null = off.
  static const _native = MethodChannel('com.samba.studio/program_encoder');
  Map<String, dynamic>? _hotspot;
  bool _hotspotBusy = false;
  String get _roomIp => (_hotspot?['ip'] as String?) ?? _localIp;
  String get _pairingJson => jsonEncode(PairingPayload(
        ip: _roomIp, port: 8088,
        wifiSsid: _hotspot?['ssid'] as String?, wifiPassword: _hotspot?['password'] as String?,
      ).toJson());

  Future<void> _setHotspot(bool on) async {
    if (_hotspotBusy) return;
    setState(() => _hotspotBusy = true);
    try {
      if (!on) {
        await _native.invokeMethod('stopHotspot');
        setState(() => _hotspot = null);
        return;
      }
      // Android asks for location (up to 12) or nearby-devices (13+) permission to create a network.
      await [Permission.locationWhenInUse, Permission.nearbyWifiDevices].request();
      // flutter_webrtc initializes lazily and would overwrite the field trial the hotspot sets for WebRTC
      // (WebRtcOwnNetwork.kt): make it initialize now, before the network starts.
      await WebRTC.initialize();
      final r = Map<String, dynamic>.from(await _native.invokeMethod<Map>('startHotspot') ?? const {});
      if (r['ok'] == true && (r['ssid'] as String?)?.isNotEmpty == true) {
        setState(() => _hotspot = r);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No se pudo crear la red propia: ${r['error'] ?? 'sin detalle'}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo crear la red propia: $e')));
      }
    } finally {
      if (mounted) setState(() => _hotspotBusy = false);
    }
  }

  /// One line about the switcher's own network (name + band), or null when off.
  String? get _hotspotLine {
    final h = _hotspot;
    if (h == null) return null;
    final band = (h['band'] as String?)?.isNotEmpty == true ? ' · ${h['band']}' : '';
    return 'Red propia: ${h['ssid']}$band';
  }

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
    // Audio follows video: the program carries the on-air camera's audio track.
    final primaryStream = primaryPeerId != null ? _subscriber.remoteStreams[primaryPeerId] : null;
    final audioTracks = primaryStream?.getAudioTracks() ?? const [];
    _encoder.setCameraSources(
      primaryTextureId: primaryRenderer?.textureId,
      secondaryTextureId: secondaryRenderer?.textureId,
      primaryAudioTrackId: audioTracks.isNotEmpty ? audioTracks.first.id : null,
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
    // Refresh the IP in case the Wi-Fi was not ready at start.
    _detectLocalIp();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        final payload = _pairingJson;
        debugPrint('[QR] payload=$payload');
        return AlertDialog(
          scrollable: true,
          title: const Row(children: [
            Icon(SdIcons.qrCode, color: Sd.magenta, size: 22),
            SizedBox(width: 10),
            Text('Emparejar una cámara'),
          ]),
          // Landscape (the usual switcher position): QR on the left, address + own-network switch on the right, so the
          // switch is never hidden below the QR.
          content: Builder(builder: (ctx) {
            final landscape = MediaQuery.of(ctx).orientation == Orientation.landscape;
            final qr = Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Sd.t1, borderRadius: BorderRadius.circular(Sd.r2)),
              child: QrImageView(data: payload, version: QrVersions.auto, size: landscape ? 150.0 : 200.0),
            );
            final info = Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: landscape ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
              Text('$_roomIp : 8088', style: SdText.heading),
              const SizedBox(height: 4),
              Text('En otro celular: Samba Air → Cámara → Switcher (celular)', style: SdText.caption,
                  textAlign: landscape ? TextAlign.start : TextAlign.center),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero, dense: true,
                title: const Text('Red propia del switcher', style: SdText.bodyHi),
                subtitle: Text(_hotspotLine ?? 'Las cámaras se conectan directo a este celular (sin router); '
                    'la SIM queda libre para emitir.', style: SdText.caption),
                value: _hotspot != null,
                onChanged: _hotspotBusy ? null : (v) async { await _setHotspot(v); setDlg(() {}); },
              ),
              // Name + password in plain sight: if the QR join fails, a camera can join from Android's Wi-Fi settings.
              if (_hotspot != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Sd.surface, borderRadius: BorderRadius.circular(Sd.r1),
                      border: Border.all(color: Sd.border)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SelectableText('Red: ${_hotspot!['ssid']}', style: SdText.label.copyWith(color: Sd.t1)),
                    const SizedBox(height: 2),
                    SelectableText('Clave: ${_hotspot!['password']}', style: SdText.label.copyWith(color: Sd.t1)),
                  ]),
                ),
            ]);
            return landscape
                ? SizedBox(width: 560, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    qr, const SizedBox(width: 20), Expanded(child: info)]))
                : Column(mainAxisSize: MainAxisSize.min, children: [qr, const SizedBox(height: 16), info]);
          }),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
        );
      }),
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
        Widget slider(String label, String value, double v, double min, double max, int div, ValueChanged<double> on) =>
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(label, style: SdText.label)),
                Text(value, style: SdText.label.copyWith(color: Sd.t1, fontWeight: FontWeight.w600)),
              ]),
              Slider(value: v, min: min, max: max, divisions: div, onChanged: on),
              const SizedBox(height: 4),
            ]);
        return StatefulBuilder(
          builder: (context, setModalState) => AlertDialog(
            title: const Row(children: [
              Icon(SdIcons.waveform, color: Sd.cyan, size: 22),
              SizedBox(width: 10),
              Expanded(child: Text('Corte automático por audio')),
            ]),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Corta a la cámara cuyo micrófono habla.', style: SdText.caption),
                const SizedBox(height: 14),
                slider('Umbral de voz', '${threshold.toStringAsFixed(0)} dBFS', threshold, -60, -10, 50, (val) {
                  setModalState(() => threshold = val); _director.updateConfig(thresholdDbfs: val);
                }),
                slider('Inicio mínimo', '${onset.toStringAsFixed(0)} ms', onset, 20, 300, 28, (val) {
                  setModalState(() => onset = val); _director.updateConfig(onsetMs: val);
                }),
                slider('Retención (evita cortes de ida y vuelta)', '${hold.toStringAsFixed(1)} s', hold, 0.5, 4, 35, (val) {
                  setModalState(() => hold = val); _director.updateConfig(holdSec: val);
                }),
                slider('Tiempo para silencio', '${silence.toStringAsFixed(1)} s', silence, 1, 6, 25, (val) {
                  setModalState(() => silence = val); _director.updateConfig(silenceSec: val);
                }),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo'))],
          ),
        );
      },
    );
  }

  void _showRtmpConfigDialog() {
    final urlCtrl = TextEditingController(text: _rtmpOut.rtmpUrl);
    final keyCtrl = TextEditingController(text: _rtmpOut.streamKey);
    bool abr = _rtmpOut.abrEnabled;
    bool audioCam = _encoder.audioCamera;
    bool audioMic = _encoder.audioMic;
    Widget sw(String title, String sub, bool v, ValueChanged<bool> on) => SwitchListTile(
          contentPadding: EdgeInsets.zero, dense: true,
          title: Text(title, style: SdText.bodyHi),
          subtitle: Text(sub, style: SdText.caption),
          value: v, onChanged: on,
        );

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModal) => AlertDialog(
          scrollable: true,
          title: const Row(children: [
            Icon(SdIcons.broadcast, color: Sd.red, size: 22),
            SizedBox(width: 10),
            Text('Emitir en vivo'),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: urlCtrl,
              style: SdText.bodyHi,
              decoration: const InputDecoration(
                labelText: 'URL del servidor (RTMP / RTMPS)',
                helperText: 'SAMBA en la PC: rtmp://IP-DEL-PC:1935/live · cualquier clave · '
                    'YouTube: rtmps://a.rtmps.youtube.com/live2 · Facebook: rtmps://live-api-s.facebook.com:443/rtmp/ · '
                    'Twitch: rtmp://live.twitch.tv/app',
                helperMaxLines: 4,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyCtrl,
              obscureText: true,
              style: SdText.bodyHi,
              decoration: const InputDecoration(labelText: 'Clave de transmisión'),
            ),
            const SizedBox(height: 8),
            sw('Bitrate adaptativo', 'Baja la calidad si la red se satura', abr, (v) => setModal(() => abr = v)),
            sw('Audio de la cámara al aire', 'El sonido sigue al corte: se escucha a quien está en pantalla',
                audioCam, (v) => setModal(() => audioCam = v)),
            sw('Micrófono de este celular', 'Para un presentador junto al switcher (con auriculares)',
                audioMic, (v) => setModal(() => audioMic = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar', style: TextStyle(color: Sd.t2))),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Sd.red),
              icon: const Icon(SdIcons.broadcast, size: 18),
              onPressed: () async {
                _rtmpOut.configure(url: urlCtrl.text.trim(), streamKey: keyCtrl.text.trim(), abrEnabled: abr);
                Navigator.pop(ctx);
                if (_encoder.isEncoding) {
                  await _encoder.setAudioSources(camera: audioCam, mic: audioMic);
                } else {
                  _encoder.audioCamera = audioCam;
                  _encoder.audioMic = audioMic;
                }
                await _rtmpOut.startStream();
                if (!mounted) return;
                if (_rtmpOut.state == RtmpState.error) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    duration: const Duration(seconds: 8),
                    content: Text('No se pudo salir en vivo: ${_rtmpOut.errorMessage}',
                        style: SdText.bodyHi.copyWith(color: Sd.red)),
                  ));
                } else if (_rtmpOut.isStreaming) {
                  // Tell the user if the program goes out without sound (mic permission denied / busy).
                  Future.delayed(const Duration(seconds: 3), () {
                    if (mounted && _rtmpOut.isStreaming && !_rtmpOut.hasAudio) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('En vivo SIN AUDIO: la cámara al aire no manda sonido y el micrófono está apagado o sin permiso.'),
                      ));
                    }
                  });
                }
              },
              label: const Text('Salir en vivo'),
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

  Widget _buildLayoutChip(String label, IconData icon, LayoutMode mode) {
    final isSelected = _mixer.mode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(Sd.r1),
      onTap: () => _mixer.setLayoutMode(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Sd.wash(Sd.cyan, 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(Sd.r1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: isSelected ? Sd.cyan : Sd.t2),
          const SizedBox(width: 5),
          Text(label, style: SdText.label.copyWith(color: isSelected ? Sd.cyan : Sd.t2,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500)),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    if (_hotspot != null) _native.invokeMethod('stopHotspot').catchError((_) => null);
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
      backgroundColor: Sd.void_,
      appBar: AppBar(
        backgroundColor: Sd.void_,
        titleSpacing: 4,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SWITCHER', style: SdText.overline.copyWith(color: Sd.magenta, letterSpacing: 1.6)),
          const SizedBox(height: 2),
          Row(children: [
            const Flexible(child: Text('Samba Studio', overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Text(':8088', style: SdText.caption),
          ]),
        ]),
        actions: [
          // Local camera (this phone's own camera as a source)
          ListenableBuilder(
            listenable: _localCam,
            builder: (context, _) {
              final on = _localCam.isActive;
              return Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  icon: Icon(on ? SdIcons.videoCamera : SdIcons.videoCameraSlash,
                      color: on ? Sd.green : Sd.t2),
                  tooltip: on ? 'Apagar cámara local' : 'Usar cámara local como fuente',
                  onPressed: _toggleLocalCamera,
                ),
                if (on)
                  IconButton(
                    icon: const Icon(SdIcons.cameraRotate),
                    tooltip: 'Girar cámara local',
                    onPressed: () => _localCam.flip(),
                  ),
              ]);
            },
          ),
          IconButton(
            icon: const Icon(SdIcons.qrCode),
            tooltip: 'Emparejar Cámara (QR)',
            onPressed: _showQrPairingDialog,
          ),
          IconButton(
            icon: const Icon(SdIcons.slidersHorizontal),
            tooltip: 'Ajustes Audio Switcher',
            onPressed: _showAudioSettingsDialog,
          ),
          // Auto / manual switching
          ListenableBuilder(
            listenable: _director,
            builder: (context, _) {
              final isAuto = _director.isAutoSwitch;
              return InkWell(
                borderRadius: BorderRadius.circular(Sd.r3),
                onTap: () => _director.toggleAutoSwitch(!isAuto),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: isAuto ? Sd.wash(Sd.cyan, 0.16) : Sd.raised,
                    borderRadius: BorderRadius.circular(Sd.r3),
                    border: Border.all(color: isAuto ? Sd.wash(Sd.cyan, 0.6) : Sd.borderStrong),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(SdIcons.sparkle, size: 15, color: isAuto ? Sd.cyan : Sd.t2),
                    const SizedBox(width: 6),
                    Text(isAuto ? 'AUTO' : 'MANUAL', style: SdText.overline.copyWith(
                        color: isAuto ? Sd.cyan : Sd.t2, letterSpacing: 0.8)),
                  ]),
                ),
              );
            },
          ),
          // Record
          ListenableBuilder(
            listenable: _recorder,
            builder: (context, _) {
              final isRec = _recorder.isRecording;
              return IconButton(
                icon: Icon(isRec ? SdIcons.record : SdIcons.record,
                    color: isRec ? Sd.magenta : Sd.t2),
                tooltip: isRec ? 'Detener Grabación SD' : 'Grabar a SD',
                onPressed: _toggleRecording,
              );
            },
          ),
          // Go live
          ListenableBuilder(
            listenable: _rtmpOut,
            builder: (context, _) {
              final isLive = _rtmpOut.isStreaming;
              return Padding(
                padding: const EdgeInsets.only(right: 10, left: 2),
                child: isLive
                    ? FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Sd.red, minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 12)),
                        icon: const Icon(SdIcons.broadcast, size: 16),
                        label: const Text('En vivo'),
                        onPressed: _rtmpOut.stopStream,
                      )
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 12)),
                        icon: const Icon(SdIcons.broadcast, size: 16, color: Sd.red),
                        label: const Text('Emitir'),
                        onPressed: _showRtmpConfigDialog,
                      ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(top: false, child: ListenableBuilder(
        listenable: Listenable.merge([_roomHost, _subscriber, _rtmpOut, _recorder, _encoder, _mixer, _localCam, _director]),
        builder: (context, _) {
          final cameras = _roomHost.cameras;
          final activePeerId = _roomHost.activePeerId;
          final previewPeerId = _roomHost.previewPeerId;
          final previewName = previewPeerId == null ? null
              : cameras.where((c) => c.id == previewPeerId).map((c) => c.name).firstOrNull;

          return Column(
            children: [
              // 1. Program monitor
              Expanded(
                flex: 4,
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Sd.void_,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: activePeerId != null ? Sd.wash(Sd.red, 0.75) : Sd.borderStrong,
                      width: activePeerId != null ? 1.5 : 1,
                    ),
                  ),
                  child: Stack(
                    children: [
                      // Program composition (single, split 50/50, PiP)
                      Positioned.fill(
                        child: ProgramLayoutView(
                          mixer: _mixer,
                          subscriber: _subscriber,
                          cameras: cameras,
                          localRenderer: _localCam.isActive ? _localCam.renderer : null,
                          localPeerId: _localCam.peerId,
                        ),
                      ),
                      // Status pills
                      Positioned(
                        top: 10, left: 10, right: 10,
                        child: Row(children: [
                          const SdPill('PROGRAMA', color: Sd.red, solid: true),
                          if (_rtmpOut.isStreaming) ...[
                            const SizedBox(width: 6),
                            _rtmpOut.reconnecting
                                ? const SdPill('RECONECTANDO…', color: Sd.amber, icon: SdIcons.arrowsClockwise)
                                : SdPill('EN VIVO · ${_rtmpOut.currentBitrateKbps} kbps', color: Sd.red,
                                    icon: SdIcons.broadcast),
                            if (!_rtmpOut.reconnecting && !_rtmpOut.hasAudio) ...[
                              const SizedBox(width: 6),
                              const SdPill('SIN AUDIO', color: Sd.amber, icon: SdIcons.speakerSlash),
                            ],
                          ],
                          if (_recorder.isRecording) ...[
                            const SizedBox(width: 6),
                            SdPill('REC · ${_recorder.fileSizeMb.toStringAsFixed(1)} MB', color: Sd.magenta,
                                icon: SdIcons.record),
                          ],
                          const Spacer(),
                          SdPill('${_encoder.width}×${_encoder.height} · ${_encoder.fps} fps', color: Sd.t2),
                        ]),
                      ),
                      // Layout selector + second camera
                      Positioned(
                        bottom: 10, left: 10, right: 10,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: const Color(0xCC000000),
                                borderRadius: BorderRadius.circular(Sd.r1 + 2),
                                border: Border.all(color: Sd.borderStrong),
                              ),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                _buildLayoutChip('1 cámara', SdIcons.square, LayoutMode.single),
                                _buildLayoutChip('Dividida', SdIcons.columns, LayoutMode.splitScreen),
                                _buildLayoutChip('PiP', SdIcons.copySimple, LayoutMode.pip),
                              ]),
                            ),
                            if (_mixer.mode == LayoutMode.single && previewName != null)
                              // CUT: the preview camera goes on air — instant, it is already at high quality.
                              FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: Sd.red, minimumSize: const Size(0, 34),
                                    padding: const EdgeInsets.symmetric(horizontal: 12)),
                                icon: const Icon(SdIcons.scissors, size: 16),
                                label: Text('CORTE → $previewName', overflow: TextOverflow.ellipsis),
                                onPressed: _director.cutToPreview,
                              ),
                            if (_mixer.mode != LayoutMode.single && cameras.length > 1)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                                decoration: BoxDecoration(
                                  color: const Color(0xCC000000),
                                  borderRadius: BorderRadius.circular(Sd.r1 + 2),
                                  border: Border.all(color: Sd.wash(Sd.cyan, 0.45)),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: _mixer.secondaryPeerId ??
                                        cameras.firstWhere((c) => c.id != _mixer.primaryPeerId, orElse: () => cameras.first).id,
                                    dropdownColor: Sd.raised,
                                    borderRadius: BorderRadius.circular(Sd.r1),
                                    style: SdText.label.copyWith(color: Sd.cyan, fontWeight: FontWeight.w600),
                                    icon: const Icon(SdIcons.caretDown, color: Sd.cyan, size: 14),
                                    items: cameras
                                        .where((c) => c.id != _mixer.primaryPeerId)
                                        .map((c) => DropdownMenuItem(value: c.id, child: Text('2ª: ${c.name}')))
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

              // 2. Multiview header
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 0),
                child: Row(children: [
                  Text('MULTIVIEW', style: SdText.overline),
                  const SizedBox(width: 8),
                  Text('${cameras.length} ${cameras.length == 1 ? 'cámara' : 'cámaras'}', style: SdText.caption),
                  const Spacer(),
                  Flexible(child: Text(previewPeerId == null
                      ? 'Tocá una cámara para prepararla en vista previa'
                      : 'Tocá la verde otra vez (o CORTE) para ponerla al aire',
                      style: SdText.caption, overflow: TextOverflow.ellipsis)),
                ]),
              ),

              // 3. Multiview cards
              Expanded(
                flex: 3,
                child: cameras.isEmpty
                    ? Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: Sd.t1, borderRadius: BorderRadius.circular(Sd.r2)),
                              child: QrImageView(
                                data: _pairingJson,
                                version: QrVersions.auto,
                                size: 92.0,
                                errorStateBuilder: (ctx, err) => const SizedBox(
                                  width: 92, height: 92,
                                  child: Center(child: Text('QR\nno disponible', textAlign: TextAlign.center)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                              const Text('Sumá cámaras', style: SdText.heading),
                              const SizedBox(height: 4),
                              const Text('Escaneá este QR desde Samba Air (Cámara → Switcher)', style: SdText.body),
                              const SizedBox(height: 2),
                              Text('o conectá a  $_roomIp:8088', style: SdText.bodyHi),
                              if (_hotspotLine != null) ...[
                                const SizedBox(height: 4),
                                Row(mainAxisSize: MainAxisSize.min, children: [
                                  const Icon(SdIcons.wifiHigh, size: 14, color: Sd.green),
                                  const SizedBox(width: 6),
                                  Text(_hotspotLine!, style: SdText.caption.copyWith(color: Sd.green)),
                                ]),
                              ],
                              const SizedBox(height: 12),
                              const Row(mainAxisSize: MainAxisSize.min, children: [
                                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.4)),
                                SizedBox(width: 8),
                                Text('Esperando cámaras en la red local…', style: SdText.caption),
                              ]),
                            ])),
                          ]),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.6,
                        ),
                        itemCount: cameras.length,
                        itemBuilder: (context, idx) {
                          final cam = cameras[idx];
                          final isActive = cam.id == activePeerId;
                          final isPreview = cam.id == previewPeerId;
                          final rx = _subscriber.received[cam.id];
                          // The switcher's own camera uses its local renderer; remote ones, the subscriber's.
                          final isLocal = cam.id == _localCam.peerId;
                          final camRenderer = isLocal ? _localCam.renderer : _subscriber.getRenderer(cam.id);
                          final hasVideo = camRenderer != null && camRenderer.srcObject != null;
                          final level = ((cam.lastAudioDbfs + 60.0) / 60.0).clamp(0.0, 1.0);

                          return GestureDetector(
                            // 1st tap: preview (it goes up to high quality); tap on the green one: on air. Long press:
                            // direct cut, for when there is no time to prepare.
                            onTap: isActive ? null
                                : () => isPreview ? _director.manualCut(cam.id) : _director.setPreview(cam.id),
                            onLongPress: isActive ? null : () => _director.manualCut(cam.id),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              clipBehavior: Clip.antiAlias,
                              decoration: BoxDecoration(
                                color: Sd.raised,
                                borderRadius: BorderRadius.circular(Sd.r2),
                                border: Border.all(
                                  color: isActive ? Sd.wash(Sd.red, 0.8) : isPreview ? Sd.wash(Sd.green, 0.8) : Sd.border,
                                  width: isActive || isPreview ? 1.5 : 1,
                                ),
                              ),
                              child: Stack(children: [
                                if (hasVideo)
                                  Positioned.fill(child: RTCVideoView(camRenderer,
                                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)),
                                // Gradient top and bottom only, so the picture stays visible
                                Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                                    stops: const [0, 0.35, 0.65, 1],
                                    colors: [
                                      Colors.black.withValues(alpha: hasVideo ? 0.65 : 0),
                                      Colors.transparent, Colors.transparent,
                                      Colors.black.withValues(alpha: hasVideo ? 0.75 : 0),
                                    ],
                                  ),
                                ))),
                                Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Row(children: [
                                        Expanded(child: Text(cam.name, style: SdText.bodyHi.copyWith(fontWeight: FontWeight.w600),
                                            overflow: TextOverflow.ellipsis)),
                                        isActive
                                            ? const SdPill('EN EL AIRE', color: Sd.red, solid: true)
                                            : isPreview
                                                ? const SdPill('VISTA PREVIA', color: Sd.green)
                                                : const SdPill('LISTA', color: Sd.t2),
                                      ]),
                                      if (!hasVideo)
                                        const Center(child: Icon(SdIcons.videoCameraSlash, color: Sd.t3, size: 22)),
                                      // Audio level: a thin bar (green → amber when loud)
                                      Row(children: [
                                        Icon(SdIcons.microphone, size: 13,
                                            color: level > 0.66 ? Sd.amber : Sd.t2),
                                        const SizedBox(width: 6),
                                        Expanded(child: ClipRRect(
                                          borderRadius: BorderRadius.circular(2),
                                          child: LinearProgressIndicator(
                                            value: level, minHeight: 3, backgroundColor: const Color(0x33FFFFFF),
                                            valueColor: AlwaysStoppedAnimation<Color>(level > 0.66 ? Sd.amber : Sd.green),
                                          ),
                                        )),
                                        const SizedBox(width: 6),
                                        Text('${cam.lastAudioDbfs.toStringAsFixed(0)} dB', style: SdText.caption),
                                        // What really arrives (check for PGM/PVW: high only for on air / preview).
                                        if (rx != null && rx.height > 0) ...[
                                          const SizedBox(width: 8),
                                          Text('${rx.height}p · ${rx.fps}', style: SdText.caption.copyWith(
                                              color: rx.height >= 720 ? Sd.cyan : Sd.t3)),
                                        ],
                                      ]),
                                    ],
                                  ),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
              ),

              // 4. Last switch
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: const BoxDecoration(
                  color: Sd.surface,
                  border: Border(top: BorderSide(color: Sd.border)),
                ),
                child: ListenableBuilder(
                  listenable: _director,
                  builder: (context, _) {
                    final lastLog = _director.switchHistory.firstOrNull ?? 'Listo para conmutar';
                    return Row(children: [
                      const Icon(SdIcons.clockCounterClockwise, size: 15, color: Sd.t3),
                      const SizedBox(width: 8),
                      Expanded(child: Text(lastLog, style: SdText.caption.copyWith(color: Sd.t2),
                          overflow: TextOverflow.ellipsis)),
                    ]);
                  },
                ),
              ),
            ],
          );
        },
      )),
    );
  }
}
