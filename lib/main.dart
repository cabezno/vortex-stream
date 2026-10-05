// =============================================================================
// Samba Air v0.6.0 — Multi-transport camera app for SAMBA
//
// Transportes:
//   SBL   — H.264, protocolo nativo SAMBA, máxima prioridad LAN.
//   WHIP  — WebRTC/H.264, funciona en LAN e internet. Engine: WHIPServer.
//   SRT   — H.265 HW, LAN solo, máxima calidad, mínima latencia.
//   RTMP  — H.264, compatible con cualquier servidor, LAN o internet.
//
// Pairing: escanear QR de SAMBA → auto-selecciona transporte óptimo.
// Preview: RTCVideoView (WHIP) o Texture nativa (SRT/RTMP/SBL).
// Tally:   pantalla pulsa roja cuando la fuente está al aire (ON AIR).
// =============================================================================
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:permission_handler/permission_handler.dart';
import 'theme/sd_icons.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/connection_config.dart';
import 'services/connection_service.dart';
import 'services/srt_connection_service.dart';
import 'services/rtmp_connection_service.dart';
import 'services/omt_connection_service.dart';
import 'services/sbl_connection_service.dart';
import 'services/camera_service.dart';
import 'services/device_capabilities.dart';
import 'theme/samba_theme.dart';
import 'services/log_service.dart';
import 'screens/mode_picker.dart';

void main() {
  // runZonedGuarded + FlutterError.onError capture BOTH framework errors and any
  // uncaught async error, route them to the on-device log, and ship that log to
  // the PC — so a crash that closes the app still leaves its trail for analysis.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await LogService.instance.init();

    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      prev?.call(details);
      LogService.instance.add('[FlutterError] ${details.exceptionAsString()}');
      LogService.instance.shipToPc(reason: 'flutter_error');
    };

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => CameraService()),
          ChangeNotifierProvider(create: (_) => ConnectionService()),
          ChangeNotifierProvider(create: (_) => SrtConnectionService()),
          ChangeNotifierProvider(create: (_) => RtmpConnectionService()),
          ChangeNotifierProvider(create: (_) => OmtConnectionService()),
          ChangeNotifierProvider(create: (_) => SblConnectionService()),
        ],
        child: const SambaAirApp(),
      ),
    );
  }, (error, stack) {
    LogService.instance.add('[UNCAUGHT] $error');
    LogService.instance.add(stack.toString());
    LogService.instance.shipToPc(reason: 'crash');
  });
}

class SambaAirApp extends StatelessWidget {
  const SambaAirApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Samba Air',
    debugShowCheckedModeBanner: false,
    theme: sambaTheme(),   // SAMBA's look (SODA): Inter, black surfaces, cyan accent — lib/theme/samba_theme.dart
    // One app, three modes: Cámara → SAMBA (the classic flow below), Cámara → Studio, Switcher.
    home: ModePicker(sambaHome: (_) => const _HomePage()),
  );
}

// ---------------------------------------------------------------------------
// Home — dispatches to connect or live screen
// ---------------------------------------------------------------------------
class _HomePage extends StatefulWidget {
  const _HomePage();
  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> with WidgetsBindingObserver {
  ConnectionConfig? _config;
  Transport         _transport = Transport.whip;
  bool              _frontCam  = false;
  bool              _torchOn   = false;
  // Talkback (engine → phone return audio). Starts unmuted — matches how SBL
  // already behaved before this button existed (always-on, no control); the
  // new part is being able to turn it off, not a new default-off surprise.
  bool              _talkbackMuted = false;
  bool              _onAir     = false;
  bool              _live      = false;
  bool              _connecting = false;  // guard against double-tap → duplicate POST
  bool              _showCtrl  = true;

  final _deviceCtrl = TextEditingController(text: 'cam1');
  final _logs       = <String>[];

  // WHIP preview renderer
  final _renderer = RTCVideoRenderer();
  // SRT/RTMP preview texture id
  int? _nativeTexId;
  // Phone preview orientation (SRT/RTMP/SBL Texture): the raw camera buffer has to be turned and shown with
  // its real aspect — it was stretched to the whole screen and looked rotated/deformed with the phone sideways.
  int    _previewTurns = 0;      // quarter turns (clockwise) to counter-rotate the preview
  bool   _previewPortraitBuf = true;   // the Texture shows the camera as a PORTRAIT image (sensor 90/270)
  String _previewDbg  = '';
  String _previewKey  = '';   // orientation+insets: re-query the rotation only when the screen turns

  @override
  void initState() {
    super.initState();
    LogService.instance.portsProvider = _logPorts;
    WidgetsBinding.instance.addObserver(this);
    _renderer.initialize();
    _loadSaved();
    _log('Samba Air v0.6.0 iniciado');
    _probeCaps();
    _probeWifiBand();
    _bandTimer = Timer.periodic(const Duration(seconds: 6), (_) => _probeWifiBand());
  }

  // Wi-Fi band the phone is on, read live (the phone can roam between bands): 2.4 GHz → recommend 5 GHz.
  int _wifiMhz = 0;
  Timer? _bandTimer;
  Future<void> _probeWifiBand() async {
    if (_live) return;
    try {
      final mhz = await _nativeChannel.invokeMethod<int>('wifiBand') ?? 0;
      if (mounted && mhz != _wifiMhz) setState(() => _wifiMhz = mhz);
    } catch (_) {}
  }

  // What this phone can do, measured once per Android/app version (see device_capabilities.dart). The camera
  // permission is asked here: the WebRTC (WHIP) check opens the camera for a few seconds, and the camera mode needs
  // it anyway. Denied → only the native part is measured; WHIP is then verified live.
  Future<void> _probeCaps() async {
    final caps = DeviceCapabilities.instance;
    caps.addListener(_onCapsChanged);
    final granted = (await Permission.camera.request()).isGranted;
    await caps.ensure(cameraGranted: granted);
    final line = caps.summary();
    if (line.isNotEmpty) _log('Este celular: $line');
    for (final t in Transport.values) {
      final sup = caps.support(t);
      if (!sup.ok) _log('${labelFor(t)} no disponible — ${sup.reason}');
    }
  }

  void _onCapsChanged() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DeviceCapabilities.instance.removeListener(_onCapsChanged);
    _bandTimer?.cancel();
    _renderer.dispose();
    _deviceCtrl.dispose();
    super.dispose();
  }

  // Ship the log to the PC when the app is backgrounded or closed, so the data
  // survives even if the user swipes the app away or Android kills it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      LogService.instance.shipToPc(reason: 'lifecycle_${state.name}');
    }
  }

  void _log(String m) {
    final n = DateTime.now();
    final t = '${n.hour.toString().padLeft(2,'0')}:'
              '${n.minute.toString().padLeft(2,'0')}:'
              '${n.second.toString().padLeft(2,'0')}';
    final line = '[$t] $m';
    debugPrint('[SambaAir] $line');
    LogService.instance.add(line);
    if (mounted) setState(() => _logs.insert(0, line));
  }

  Future<void> _loadSaved() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString('device_name');
    if (name != null) _deviceCtrl.text = name;
    // Ship logs from the very start (before pairing) to the last PC we paired with.
    final lastHost = p.getString('last_engine_host');
    if (lastHost != null && lastHost.isNotEmpty && !LogService.instance.hasTarget) {
      LogService.instance.configure(host: lastHost, device: _deviceCtrl.text.trim());
    }
  }

  Future<void> _saveName() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('device_name', _deviceCtrl.text.trim());
  }

  // ---- Transport label / color (single source of truth) ----
  static String labelFor(Transport t) => switch (t) {
    Transport.whip => 'WHIP',
    Transport.srt  => 'SRT',
    Transport.rtmp => 'RTMP',
    Transport.omt  => 'OMT',
    Transport.sbl  => 'SBL',
  };

  static Color colorFor(Transport t) => switch (t) {
    Transport.sbl  => Sd.cyan,       // SAMBA's own protocol: the accent
    Transport.srt  => Sd.green,
    Transport.whip => Sd.magenta,
    Transport.rtmp => Sd.amber,
    Transport.omt  => Sd.violet,
  };

  String get _transportLabel => labelFor(_transport);
  Color  get _transportColor => colorFor(_transport);

  // ---- QR scan ----
  Future<void> _scan() async {
    if (!(await Permission.camera.request()).isGranted) {
      _log('Permiso de cámara denegado'); return;
    }
    if (!mounted) return;
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScanPage()),
    );
    if (raw == null) return;
    final cfg = ConnectionConfig.tryParse(raw);
    if (cfg == null) {
      _log('QR no reconocido como Samba Air'); return;
    }
    // SAMBA's QR lists the transports in its order of preference; take the first one THIS phone can do.
    final caps = DeviceCapabilities.instance;
    final chosen = caps.firstSupported(cfg.availableTransports) ?? cfg.preferredTransport;
    if (chosen != cfg.preferredTransport) {
      _log('SAMBA sugiere ${labelFor(cfg.preferredTransport)}, pero ${caps.support(cfg.preferredTransport).reason} '
           '→ uso ${labelFor(chosen)}');
    }
    setState(() {
      _config    = cfg;
      _transport = chosen;
    });
    LogService.instance.configure(host: cfg.host, device: _deviceCtrl.text.trim());
    SharedPreferences.getInstance().then((p) => p.setString('last_engine_host', cfg.host));

    // Network layer: if the QR includes WiFi credentials (PC hotspot active),
    // connect to that network automatically before the user taps Go Live.
    if (cfg.wifi != null) {
      await _connectWifi(cfg.wifi!);
    }

    _log('Emparejado con ${cfg.host} — ${cfg.hasWifi ? "WiFi+${_transportLabel}" : _transportLabel}');
  }

  String _wifiStatus = '';
  bool   _wifiConnecting = false;

  static const _nativeChannel = MethodChannel('com.vortex.vortexcam/native');

  Future<void> _connectWifi(WifiConfig wifi) async {
    setState(() { _wifiConnecting = true; _wifiStatus = 'Conectando a "${wifi.ssid}"...'; });
    _log('WiFi: conectando a "${wifi.ssid}"...');
    try {
      final ok = await _nativeChannel.invokeMethod<bool>('connectWifi', {
        'ssid':     wifi.ssid,
        'password': wifi.password,
      }).timeout(const Duration(seconds: 20));
      if (ok == true) {
        setState(() { _wifiStatus = '✓ Conectado a "${wifi.ssid}"'; });
        _log('WiFi: conectado a "${wifi.ssid}"');
      } else {
        setState(() { _wifiStatus = 'No se pudo conectar a "${wifi.ssid}" — verificá la contraseña'; });
        _log('WiFi: falló la conexión a "${wifi.ssid}"');
      }
    } catch (e) {
      setState(() { _wifiStatus = 'Error WiFi: $e'; });
      _log('WiFi error: $e');
    } finally {
      setState(() { _wifiConnecting = false; });
    }
  }

  // Where SAMBA can receive our log over HTTP for the CURRENT transport: WHIP → the WHIP server port first;
  // SRT / SBL / RTMP / OMT → the remote-control port (:9000, always on) first. Both handle /phonelog.
  List<int> _logPorts() {
    var whipPort = 8080;
    final u = _config?.whip?.url;
    if (u != null) {
      final p = Uri.tryParse(u);
      if (p != null && p.hasPort) whipPort = p.port;
    }
    return _transport == Transport.whip ? [whipPort, 9000] : [9000, whipPort];
  }

  // ---- Manual entry ----
  Future<void> _manualEntry() async {
    // Every transport the app has, not only the three that had a manual path: SBL and OMT were reachable ONLY by
    // scanning SAMBA's QR.
    final items = <String>['WHIP (WebRTC)', 'SRT', 'RTMP', 'SBL', 'OMT'];
    final caps = DeviceCapabilities.instance;
    final itemT = <String, Transport>{
      'WHIP (WebRTC)': Transport.whip, 'SRT': Transport.srt, 'RTMP': Transport.rtmp,
      'SBL': Transport.sbl, 'OMT': Transport.omt,
    };
    bool okItem(String e) => caps.support(itemT[e]!).ok;
    String selected = items.contains(_transportLabel) && okItem(_transportLabel)
        ? _transportLabel : items.firstWhere(okItem, orElse: () => items.first);
    final unsupported = items.where((e) => !okItem(e)).toList();
    final ctrl = TextEditingController();

    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // Scrollable: in landscape on a small phone (Galaxy A10, 720 px tall) the capability line + reasons pushed
          // the buttons on top of the address field.
          scrollable: true,
          title: const Text('Conexión manual'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (caps.summary().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Este celular: ${caps.summary()}',
                    style: SdText.caption),
              ),
            DropdownButtonFormField<String>(
              value: selected,
              // Only what this phone can do is selectable; the rest stays visible, greyed, with its reason below.
              items: items.map((e) => DropdownMenuItem(
                value: e,
                enabled: okItem(e),
                child: Text(okItem(e) ? e : '$e — no disponible',
                    style: okItem(e) ? SdText.bodyHi : SdText.bodyHi.copyWith(color: Sd.t3)),
              )).toList(),
              onChanged: (v) => setState(() => selected = v!),
              decoration: const InputDecoration(labelText: 'Protocolo'),
            ),
            for (final e in unsupported)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('$e: ${caps.support(itemT[e]!).reason}',
                    style: SdText.caption.copyWith(color: Sd.amber)),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: _urlLabel(selected),
                hintText: _urlHint(selected),
                border: const OutlineInputBorder(),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {'proto': selected, 'url': ctrl.text.trim()}),
              child: const Text('Usar'),
            ),
          ],
        ),
      ),
    );
    if (result == null || result['url']!.isEmpty) return;

    final proto = result['proto']!;
    final url   = result['url']!;
    ConnectionConfig cfg;
    Transport t;
    if (proto.contains('SRT')) {
      // Accept "IP:port" and also "srt://IP:port?..." (what SAMBA shows) — splitting the raw URL on ':'
      // used to make the host "srt".
      final hp = url.replaceFirst(RegExp(r'^srt://', caseSensitive: false), '').split(RegExp(r'[/?]')).first;
      final parts = hp.split(':');
      final ip = parts[0];
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 8890 : 8890;
      cfg = ConnectionConfig.fromSrtIp(ip, port: port);
      t   = Transport.srt;
    } else if (proto.contains('RTMP')) {
      cfg = ConnectionConfig.fromRtmpUrl(url);
      t   = Transport.rtmp;
    } else if (proto == 'SBL') {
      final hp = url.replaceFirst(RegExp(r'^sbl://', caseSensitive: false), '').split(RegExp(r'[/?]')).first;
      final parts = hp.split(':');
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 8890 : 8890;
      cfg = ConnectionConfig.fromSblIp(parts[0], port: port,
          sourceName: _deviceCtrl.text.trim().isEmpty ? 'SambaAir' : _deviceCtrl.text.trim());
      t   = Transport.sbl;
    } else if (proto == 'OMT') {
      // OMT: the phone LISTENS and SAMBA connects to it — the field is only the port to listen on.
      cfg = ConnectionConfig.fromOmtPort(int.tryParse(url.split(':').last) ?? 5960);
      t   = Transport.omt;
    } else {
      cfg = ConnectionConfig.fromWhipUrl(url);
      t   = Transport.whip;
    }
    setState(() { _config = cfg; _transport = t; });
    LogService.instance.configure(host: cfg.host, device: _deviceCtrl.text.trim());
    SharedPreferences.getInstance().then((p) => p.setString('last_engine_host', cfg.host));
    _log('Manual: $proto → $url');
  }

  String _urlLabel(String proto) {
    if (proto == 'SBL')         return 'IP:puerto de SAMBA (ej. 192.168.1.2:8890)';
    if (proto == 'OMT')         return 'Puerto donde escucha el celular (ej. 5960)';
    if (proto.contains('SRT'))  return 'IP:puerto (ej. 192.168.1.2:8890)';
    if (proto.contains('RTMP')) return 'rtmp://ip/app/clave';
    return 'http://ip:8080/whip/';
  }
  String _urlHint(String proto) {
    if (proto == 'SBL')         return '192.168.1.2:8890';
    if (proto == 'OMT')         return '5960';
    if (proto.contains('SRT'))  return '192.168.137.1:8890';
    if (proto.contains('RTMP')) return 'rtmp://192.168.1.2:1935/live/vortexcam';
    return 'http://192.168.137.1:8080/whip/';
  }

  // ---- Go live ----
  Future<void> _connect() async {
    // Guard against double-tap: a second tap while still connecting would fire
    // a duplicate WHIP POST, which the engine then had to reject. Block re-entry.
    if (_connecting || _live) { _log('Ya conectando/conectado — ignorando'); return; }
    final cfg = _config;
    if (cfg == null) { _log('Sin configuración'); return; }
    final sup = DeviceCapabilities.instance.support(_transport);
    if (!sup.ok) { _log('$_transportLabel no se puede usar en este celular: ${sup.reason}'); return; }

    setState(() => _connecting = true);
    try {
      if (!(await Permission.camera.request()).isGranted) {
        _log('Permiso de cámara denegado'); return;
      }
      // Unlike camera, a denied mic permission does NOT block the connection —
      // video-only streaming is still useful. But it used to fail completely
      // silently: getUserMedia's audio request just came back without a track,
      // WHIP negotiated video-only (Opus_PT=-1 in the offer), and nothing ever
      // told the user why SAMBA "doesn't hear" the phone. Surface it instead.
      if (!(await Permission.microphone.request()).isGranted) {
        _log('Permiso de micrófono denegado — se conecta solo con video, '
             'sin audio ni talkback. Activalo en Ajustes > Apps > Samba Air > Permisos.');
      }
      await _saveName();

      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      // Master watchdog. No matter which transport await stalls (camera HAL,
      // WiFi join, native encoder, ICE), this releases the "connecting" state so
      // the UI never freezes on the spinner — the user gets an error and can
      // retry WITHOUT killing the app (the original bug).
      await Future(() async {
        switch (_transport) {
          case Transport.whip: await _connectWhip(cfg);
          case Transport.srt:  await _connectSrt(cfg);
          case Transport.rtmp: await _connectRtmp(cfg);
          case Transport.omt:  await _connectOmt(cfg);
          case Transport.sbl:  await _connectSbl(cfg);
        }
      }).timeout(const Duration(seconds: 40));
    } on TimeoutException {
      _log('Tiempo de espera agotado al conectar ($_transportLabel) — cancelado');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (e) {
      _log('Error al conectar: $e');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } finally {
      if (mounted) setState(() => _connecting = false);
      // Send the connection trail to the PC after every attempt (success or not)
      // so a failed/hung connect is analysable locally.
      LogService.instance.shipToPc(reason: _live ? 'connected' : 'connect_failed');
    }
  }

  // -----------------------------------------------------------------------
  // WHIP (WebRTC) — uses flutter_webrtc via ConnectionService
  // -----------------------------------------------------------------------
  Future<void> _connectWhip(ConnectionConfig cfg) async {
    final whip = cfg.whip;
    if (whip == null) { _log('Sin config WHIP'); return; }

    _log('WHIP: iniciando cámara...');
    final cam = context.read<CameraService>();
    await cam.initialize();
    _renderer.srcObject = cam.stream;

    final conn = context.read<ConnectionService>();
    try {
      // Extract IP + port from WHIP URL
      final uri  = Uri.parse(whip.url);
      final devId = _deviceCtrl.text.trim().isEmpty ? 'cam1' : _deviceCtrl.text.trim();

      await conn.connect(
        engineIp:    uri.host,
        enginePort:  uri.port,
        sourceId:    devId,
        sourceName:  devId,
        stream:      cam.stream!,
        cameraService: cam,
      );

      // Listen for on_air changes
      conn.addListener(() {
        if (mounted) setState(() => _onAir = conn.isOnAir);
      });

      setState(() => _live = true);
      _setKeepAlive(true);
      _log('WHIP conectado → ${cfg.host}');
    } catch (e) {
      _log('WHIP error: $e');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await conn.disconnect();
    }
  }

  // -----------------------------------------------------------------------
  // OMT — Camera2 + VMX (libvmx ARM64) → OMT TCP server
  // -----------------------------------------------------------------------
  Future<void> _connectOmt(ConnectionConfig cfg) async {
    final omtCfg = cfg.omt;
    final port   = omtCfg?.port ?? 5960;

    _log('OMT: iniciando sender...');
    final omt = context.read<OmtConnectionService>();
    omt.configure(
      width:   cfg.video.width,
      height:  cfg.video.height,
      fps:     cfg.video.fps,
      quality: omtCfg?.quality ?? 2,
      name:    _deviceCtrl.text.trim().isEmpty ? 'ZambaAir' : _deviceCtrl.text.trim(),
    );

    try {
      await omt.start(port: port);
      setState(() { _live = true; });
      _setKeepAlive(true);
      _log('OMT sender activo → escuchando en :$port');
      _log('VortexEngine: Herramientas → Fuentes OMT → IP del cel → Conectar OMT');

      Timer.periodic(const Duration(seconds: 2), (t) {
        if (!_live) { t.cancel(); return; }
        if (mounted) setState(() {});
      });
    } catch (e) {
      _log('OMT error: $e');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // -----------------------------------------------------------------------
  // SRT — CameraX + MediaCodec H.265 → MPEG-TS → libsrt
  // -----------------------------------------------------------------------
  Future<void> _connectSrt(ConnectionConfig cfg) async {
    final srtCfg = cfg.srt;
    if (srtCfg == null) { _log('Sin config SRT'); return; }

    final srt = context.read<SrtConnectionService>();
    srt.configure(
      width:            cfg.video.width,
      height:           cfg.video.height,
      targetBitrateBps: cfg.video.maxKbps * 1000,
      srtLatencyMs:     srtCfg.latencyMs,
    );

    try {
      // Open camera first — encoder needs the camera surface to get frames.
      _log('SRT: iniciando cámara...');
      await srt.startCamera(frontCamera: _frontCam);
      _nativeTexId = srt.textureId;

      _log('SRT: conectando a ${srtCfg.host}:${srtCfg.port}...');
      await srt.connectTo(srtCfg.host, port: srtCfg.port);
      setState(() { _live = true; });
      _setKeepAlive(true);
      _log('SRT conectado → ${srtCfg.host}:${srtCfg.port}');

      // Poll stats
      Timer.periodic(const Duration(seconds: 2), (t) {
        if (!_live) { t.cancel(); return; }
        if (mounted) setState(() {});
      });
    } catch (e) {
      _log('SRT error: $e');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // -----------------------------------------------------------------------
  // RTMP — Camera2 + MediaCodec H.264 → RTMP
  // -----------------------------------------------------------------------
  Future<void> _connectRtmp(ConnectionConfig cfg) async {
    final rtmpCfg = cfg.rtmp;
    if (rtmpCfg == null) { _log('Sin config RTMP'); return; }

    _log('RTMP: iniciando cámara nativa...');
    final rtmp = context.read<RtmpConnectionService>();
    rtmp.configure(
      width:      cfg.video.width,
      height:     cfg.video.height,
      bitrateBps: cfg.video.maxKbps * 1000,
    );

    try {
      await rtmp.startCamera(frontCamera: _frontCam);
      _nativeTexId = rtmp.textureId;
      await rtmp.connect(rtmpCfg.url);
      setState(() { _live = true; });
      _setKeepAlive(true);
      _log('RTMP conectado → ${rtmpCfg.url}');

      Timer.periodic(const Duration(seconds: 2), (t) {
        if (!_live) { t.cancel(); return; }
        if (mounted) setState(() {});
      });
    } catch (e) {
      _log('RTMP error: $e');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // -----------------------------------------------------------------------
  // SBL — Samba Broadcast Link (protocolo nativo SAMBA, UDP, H.264)
  // -----------------------------------------------------------------------
  Future<void> _connectSbl(ConnectionConfig cfg) async {
    final sblCfg = cfg.sbl;
    if (sblCfg == null) { _log('Sin config SBL'); return; }
    final sbl = context.read<SblConnectionService>();
    // SBL on LAN aims for MAXIMUM quality (4K @ 30 Mbps). The native encoder
    // falls back down a ladder (1080p/720p/540p) if the device can't do 4K, and
    // RS FEC absorbs packet loss without dropping resolution.
    await sbl.configure(
      width:            3840,
      height:           2160,
      targetBitrateBps: 30000000,
    );
    try {
      await sbl.startCamera(frontCamera: _frontCam);
      _nativeTexId = sbl.textureId;
      await sbl.connect(
        sblCfg.host,
        port:       sblCfg.port,
        sourceName: _deviceCtrl.text.trim().isEmpty ? 'ZambaAir' : _deviceCtrl.text.trim(),
      );
      setState(() { _live = true; });
      _setKeepAlive(true);
      _log('SBL conectado → ${sblCfg.host}:${sblCfg.port}');
      Timer.periodic(const Duration(seconds: 2), (t) {
        if (!_live) { t.cancel(); return; }
        if (mounted) setState(() {});
      });
    } catch (e) {
      _log('SBL error: $e');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  // ---- Keep-alive while live ----
  // Foreground service (camera|microphone) + Wi-Fi/CPU locks + screen on, for EVERY transport: without it the
  // transmission died as soon as the phone locked (Android took the camera and let Wi-Fi sleep; 2026-10-03).
  static const _keepAliveCh = MethodChannel('com.vortex.vortexcam/keepalive');
  Future<void> _setKeepAlive(bool on) async {
    try {
      if (on) {
        // Android 13+: the service's notification needs this permission (the service runs either way).
        if (await Permission.notification.isDenied) await Permission.notification.request();
        await _keepAliveCh.invokeMethod('start', {'text': '$_transportLabel → ${_config?.host ?? ''}'});
      } else {
        await _keepAliveCh.invokeMethod('stop');
      }
    } catch (e) {
      _log('keep-alive: $e');
    }
  }

  // ---- Disconnect ----
  Future<void> _disconnect() async {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    setState(() { _live = false; _onAir = false; });
    _setKeepAlive(false);

    switch (_transport) {
      case Transport.whip:
        final conn = context.read<ConnectionService>();
        _renderer.srcObject = null;
        await conn.disconnect();
        context.read<CameraService>().dispose();
      case Transport.srt:
        await context.read<SrtConnectionService>().stop();
      case Transport.rtmp:
        await context.read<RtmpConnectionService>().stopCamera();
        _nativeTexId = null;
      case Transport.omt:
        await context.read<OmtConnectionService>().stop();
      case Transport.sbl:
        await context.read<SblConnectionService>().stop();
        _nativeTexId = null;
    }
    _log('Desconectado');
    // Camera/connection closed → push the session log to the PC for analysis.
    LogService.instance.shipToPc(reason: 'disconnect');
  }

  // ---- Flip & torch ----
  Future<void> _flip() async {
    setState(() => _frontCam = !_frontCam);
    switch (_transport) {
      case Transport.whip:
        final t = context.read<CameraService>().stream?.getVideoTracks().firstOrNull;
        if (t != null) await Helper.switchCamera(t);
      case Transport.srt:
        await const MethodChannel('com.vortex.vortexcam/native')
            .invokeMethod('flipCamera');
      case Transport.rtmp:
        await context.read<RtmpConnectionService>().flipCamera();
      case Transport.omt:
        break; // camera flip handled internally by OmtStreamPlugin
      case Transport.sbl:
        // SBL uses the same native Camera2 pipeline as SRT (it used to do nothing here).
        await const MethodChannel('com.vortex.vortexcam/native')
            .invokeMethod('flipCamera');
    }
    // The other camera usually has another sensor orientation: re-query the preview rotation.
    _previewKey = '';
    await _refreshPreviewRotation();
  }

  Future<void> _toggleTorch() async {
    setState(() => _torchOn = !_torchOn);
    switch (_transport) {
      case Transport.whip:
        final t = context.read<CameraService>().stream?.getVideoTracks().firstOrNull;
        if (t != null) await t.applyConstraints({'torch': _torchOn});
      case Transport.srt:
        // SRT uses native plugin — torch via channel
        await const MethodChannel('com.vortex.vortexcam/native')
            .invokeMethod('setTorch', {'on': _torchOn});
      case Transport.rtmp:
        await context.read<RtmpConnectionService>().setTorch(_torchOn);
      case Transport.omt:
        break; // torch not yet wired for OMT
      case Transport.sbl:
        break;
    }
  }

  // ---- Talkback mute (engine → phone return audio) ----
  // Only wired for SBL (native receiver in VortexCamPlugin.kt, always running
  // once startSbl() connects) and WHIP (ConnectionService.onTrack). SRT/RTMP/
  // OMT don't carry a return audio channel at all yet.
  Future<void> _toggleTalkback() async {
    setState(() => _talkbackMuted = !_talkbackMuted);
    switch (_transport) {
      case Transport.sbl:
        await const MethodChannel('com.vortex.vortexcam/native')
            .invokeMethod('setTalkbackMuted', {'muted': _talkbackMuted});
      case Transport.whip:
        context.read<ConnectionService>().setTalkbackMuted(_talkbackMuted);
      case Transport.srt:
      case Transport.rtmp:
      case Transport.omt:
        break; // no return audio channel on this transport yet
    }
  }

  // ====================================================================
  // Build
  // ====================================================================
  @override
  Widget build(BuildContext context) =>
      _live ? _buildLiveView() : _buildConnectView();

  // -----------------------------------------------------------------------
  // Connect screen
  // -----------------------------------------------------------------------
  Widget _buildConnectView() {
    final configured = _config != null;
    final caps = DeviceCapabilities.instance.summary();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CÁMARA  →  SAMBA', style: SdText.overline.copyWith(color: Sd.cyan, letterSpacing: 1.6)),
          const SizedBox(height: 2),
          const Text('Samba Air'),
        ]),
        actions: [
          IconButton(tooltip: 'Registro', icon: const Icon(SdIcons.article), onPressed: _showLogs),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          // Destination
          if (_config != null) ...[
            _destinationCard(),
            const SizedBox(height: 12),
          ],
          _wifiBandHint(),
          const SizedBox(height: 16),

          // Camera name
          TextField(
            controller: _deviceCtrl,
            style: SdText.bodyHi,
            decoration: const InputDecoration(
              labelText: 'Nombre de cámara',
              hintText: 'cam1',
              prefixIcon: Icon(SdIcons.videoCamera, size: 20),
            ),
          ),
          const SizedBox(height: 16),

          // Transport selector (only when several are offered)
          if (_config != null && _transportOptions.length > 1) ...[
            _buildTransportPicker(),
            const SizedBox(height: 16),
          ],

          // QR + go live
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _scan,
                icon: const Icon(SdIcons.qrCode, size: 20),
                label: const Text('Escanear QR'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: (configured && !_connecting && !_wifiConnecting) ? _connect : null,
                icon: _connecting
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Sd.onAccent))
                    : const Icon(SdIcons.broadcast, size: 20),
                label: Text(_wifiConnecting ? 'Conectando Wi-Fi…'
                    : _connecting ? 'Conectando…' : 'Salir en vivo · $_transportLabel',
                    overflow: TextOverflow.ellipsis),
                style: FilledButton.styleFrom(backgroundColor: _transportColor),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _manualEntry,
              icon: const Icon(SdIcons.keyboard, size: 18),
              label: const Text('Ingresar manualmente'),
            ),
          ),
          if (caps.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(SdIcons.deviceMobile, size: 15, color: Sd.t3),
              const SizedBox(width: 6),
              Expanded(child: Text('Este celular: $caps', style: SdText.caption)),
            ]),
          ],
          const SizedBox(height: 24),
          _buildTransportLegend(),
        ],
      )),
    );
  }

  // Where the phone sends + the hotspot Wi-Fi it joins (only when the QR brought one).
  Widget _destinationCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Sd.wash(_transportColor, 0.07),
      borderRadius: BorderRadius.circular(Sd.r2),
      border: Border.all(color: Sd.wash(_transportColor, 0.35)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(SdIcons.desktop, color: _transportColor, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(_config!.host, style: SdText.heading)),
        SdPill(_transportLabel, color: _transportColor),
      ]),
      if (_config!.hasWifi) ...[
        const SizedBox(height: 10),
        Row(children: [
          if (_wifiConnecting)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
          else
            Icon(_wifiStatus.startsWith('✓') ? SdIcons.wifiHigh : SdIcons.wifiSlash,
                size: 16, color: _wifiStatus.startsWith('✓') ? Sd.green : Sd.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(
            _wifiStatus.isEmpty ? 'Wi-Fi: ${_config!.wifi!.ssid}' : _wifiStatus,
            style: SdText.label.copyWith(color: _wifiStatus.startsWith('✓') ? Sd.green : Sd.amber),
          )),
        ]),
      ],
    ]),
  );

  // 2.4 GHz is crowded and slower: with several phones or 4K, SAMBA recommends 5 GHz or above (Wi-Fi 5/6/6E/7).
  // Read live from the phone (it can roam between bands).
  Widget _wifiBandHint() {
    if (_wifiMhz <= 0) return const SizedBox.shrink();
    final is24 = _wifiMhz < 3000;
    final band = is24 ? '2,4 GHz' : _wifiMhz < 5925 ? '5 GHz' : '6 GHz';
    if (!is24) {
      return Row(children: [
        const Icon(SdIcons.wifiHigh, size: 15, color: Sd.green),
        const SizedBox(width: 6),
        Text('Wi-Fi $band', style: SdText.caption.copyWith(color: Sd.green)),
      ]);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Sd.wash(Sd.amber, 0.07),
        borderRadius: BorderRadius.circular(Sd.r1),
        border: Border.all(color: Sd.wash(Sd.amber, 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(SdIcons.wifiMedium, size: 18, color: Sd.amber),
        const SizedBox(width: 10),
        Expanded(child: Text(
          'Estás en Wi-Fi de 2,4 GHz. Para varias cámaras o 4K se recomienda una red de 5 GHz o superior: '
          'con 2,4 GHz pueden perderse cuadros.',
          style: SdText.label.copyWith(color: Sd.amber, height: 1.35),
        )),
      ]),
    );
  }

  List<Transport> get _transportOptions {
    if (_config == null) return Transport.values;
    return [
      if (_config!.hasSbl)  Transport.sbl,
      if (_config!.hasOmt)  Transport.omt,
      if (_config!.hasSrt)  Transport.srt,
      if (_config!.hasWhip) Transport.whip,
      if (_config!.hasRtmp) Transport.rtmp,
    ];
  }

  Widget _buildTransportPicker() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('TRANSPORTE', style: SdText.overline),
    const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: _transportOptions.map((t) {
      final active = _transport == t;
      final color  = colorFor(t);
      return InkWell(
        borderRadius: BorderRadius.circular(Sd.r3),
        onTap: () => setState(() => _transport = t),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: active ? Sd.wash(color, 0.14) : Sd.raised,
            borderRadius: BorderRadius.circular(Sd.r3),
            border: Border.all(color: active ? Sd.wash(color, 0.6) : Sd.borderStrong),
          ),
          child: Text(labelFor(t), style: SdText.label.copyWith(
              color: active ? color : Sd.t2, fontWeight: active ? FontWeight.w600 : FontWeight.w500)),
        ),
      );
    }).toList()),
  ]);

  Widget _buildTransportLegend() => Container(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
    decoration: BoxDecoration(
      color: Sd.surface,
      borderRadius: BorderRadius.circular(Sd.r2),
      border: Border.all(color: Sd.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('PROTOCOLOS', style: SdText.overline),
      const SizedBox(height: 8),
      _LegendRow(color: colorFor(Transport.sbl),  label: 'SBL',  desc: 'LAN · H.264 · protocolo propio de SAMBA'),
      _LegendRow(color: colorFor(Transport.srt),  label: 'SRT',  desc: 'LAN · H.265 · baja latencia'),
      _LegendRow(color: colorFor(Transport.whip), label: 'WHIP', desc: 'LAN e internet · H.264 · WebRTC, se adapta a la red'),
      _LegendRow(color: colorFor(Transport.rtmp), label: 'RTMP', desc: 'LAN e internet · H.264 · compatible'),
      _LegendRow(color: colorFor(Transport.omt),  label: 'OMT',  desc: 'LAN · VMX 4:2:2 · máxima calidad'),
    ]),
  );

  // -----------------------------------------------------------------------
  // Live view
  // -----------------------------------------------------------------------
  Future<void> _refreshPreviewRotation() async {
    try {
      final m = await _nativeChannel.invokeMethod<Map>('previewRotation');
      if (m == null || !mounted) return;
      final sensor  = (m['sensor']  as int?) ?? 90;
      final display = (m['display'] as int?) ?? 0;
      final front   = (m['front']   as bool?) ?? false;
      // Upright in portrait already → only undo the display rotation (back: −display, front: +display).
      final turns = ((front ? display : (360 - display)) % 360) ~/ 90;
      final portraitBuf = sensor % 180 == 90;
      final dbg = 'giro ${turns * 90}° · sensor $sensor° · pantalla $display°';
      if (turns != _previewTurns || portraitBuf != _previewPortraitBuf || dbg != _previewDbg) {
        setState(() { _previewTurns = turns; _previewPortraitBuf = portraitBuf; _previewDbg = dbg; });
      }
    } catch (_) {/* camera not started yet */}
  }

  Widget _buildLiveView() {
    // Re-query the preview rotation only when the screen turns (orientation / insets change; the insets also
    // change between landscape-left and landscape-right). No polling: it froze the app on start (2026-10-01).
    final mq = MediaQuery.of(context);
    final pk = '${mq.orientation}|${mq.viewPadding}';
    if (pk != _previewKey) {
      _previewKey = pk;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refreshPreviewRotation());
    }
    // Stats per transport
    double bitrate = 0;
    int    latency = 0;
    bool   onAir   = _onAir;
    bool   reconnecting = false;

    switch (_transport) {
      case Transport.whip:
        final conn = context.watch<ConnectionService>();
        latency = conn.latencyMs;
        onAir   = conn.isOnAir;
      case Transport.srt:
        final srt = context.watch<SrtConnectionService>();
        bitrate = srt.bitrateMbps;
        reconnecting = srt.reconnecting;
        latency = srt.latencyMs;
        onAir   = srt.isOnAir;
      case Transport.rtmp:
        final rtmp = context.watch<RtmpConnectionService>();
        bitrate = rtmp.bitrateMbps;
        reconnecting = rtmp.reconnecting;
        latency = rtmp.latencyMs;
      case Transport.omt:
        final omt = context.watch<OmtConnectionService>();
        bitrate = omt.mbpsSent;
        onAir   = omt.connected;
      case Transport.sbl:
        final sbl = context.watch<SblConnectionService>();
        bitrate = sbl.mbpsSent;
        reconnecting = sbl.reconnecting;
        onAir   = sbl.isOnAir;
    }

    Widget preview;
    switch (_transport) {
      case Transport.whip:
        preview = RTCVideoView(
          _renderer,
          mirror: _frontCam,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        );
      case Transport.srt:
      case Transport.rtmp:
      case Transport.sbl:
        final texId = _nativeTexId;
        preview = texId != null
            ? Stack(fit: StackFit.expand, children: [
                // Real aspect of what the Texture shows (1920×1080 camera buffer, upright = portrait 9:16),
                // turned by _previewTurns: AspectRatio keeps it undeformed, Center letterboxes it.
                Center(child: AspectRatio(
                  aspectRatio: (_previewPortraitBuf != (_previewTurns.isOdd)) ? 9 / 16 : 16 / 9,
                  child: RotatedBox(quarterTurns: _previewTurns, child: Texture(textureId: texId)),
                )),
                Positioned(left: 10, bottom: 10, child: Text(_previewDbg, style: SdText.caption)),
              ])
            : const Center(child: CircularProgressIndicator());
      case Transport.omt:
        // OMT uses Camera2 directly in native code — show status overlay
        final omt = context.watch<OmtConnectionService>();
        preview = Container(
          color: Sd.void_,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(SdIcons.videoCamera, size: 56, color: omt.connected ? Sd.violet : Sd.t3),
              const SizedBox(height: 14),
              Text(omt.connected ? 'OMT — SAMBA conectado' : 'OMT — esperando a SAMBA…',
                  style: SdText.heading.copyWith(color: omt.connected ? Sd.violet : Sd.t2)),
              if (omt.isStreaming) ...[
                const SizedBox(height: 8),
                Text('Puerto ${omt.listenPort} · ${omt.mbpsSent.toStringAsFixed(1)} Mbps', style: SdText.label),
                Text('${omt.framesSent} cuadros enviados', style: SdText.caption),
              ],
            ]),
          ),
        );
    }

    return Scaffold(
      backgroundColor: Sd.void_,
      body: GestureDetector(
        onTap: () => setState(() => _showCtrl = !_showCtrl),
        child: Stack(fit: StackFit.expand, children: [
          preview,

          // Tally: full screen red pulse when ON AIR
          if (onAir)
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: 1,
                duration: const Duration(milliseconds: 300),
                // Tally as a soft red frame, not a red wash over the picture.
                child: Container(decoration: BoxDecoration(border: Border.all(color: Sd.wash(Sd.red, 0.85), width: 4))),
              ),
            ),

          // ON AIR badge
          if (onAir)
            const Positioned(top: 48, left: 16, child: _OnAirBadge()),

          // Transport + stats (top-right)
          Positioned(
            top: 44,
            right: 16,
            child: _statsBar(bitrate, latency, _transportLabel, _transportColor, reconnecting: reconnecting),
          ),

          // Log button
          Positioned(
            top: 4, right: 4,
            child: IconButton(
              icon: const Icon(SdIcons.article, size: 18, color: Sd.t3),
              onPressed: _showLogs,
            ),
          ),

          // Controls
          if (_showCtrl)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: _controlBar(),
            ),
        ]),
      ),
    );
  }

  Widget _statsBar(double bitMbps, int latMs, String proto, Color color, {bool reconnecting = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: const Color(0xB3000000),
      borderRadius: BorderRadius.circular(Sd.r3),
      border: Border.all(color: Sd.borderStrong),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 7),
      Text(proto, style: SdText.overline.copyWith(color: color, letterSpacing: 0.8)),
      const SizedBox(width: 10),
      // The link dropped and the app is reconnecting by itself (camera and encoder keep running).
      if (reconnecting)
        Text('Reconectando…', style: SdText.label.copyWith(color: Sd.amber, fontWeight: FontWeight.w600))
      else if (bitMbps > 0)
        Text('${bitMbps.toStringAsFixed(1)} Mbps', style: SdText.label.copyWith(color: Sd.t1)),
      if (latMs > 0) ...[
        const SizedBox(width: 8),
        Text('$latMs ms', style: SdText.caption),
      ],
    ]),
  );

  Widget _controlBar() => Container(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 36),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [Color(0xE6000000), Color(0x00000000)],
      ),
    ),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      _ctrlBtn(SdIcons.cameraRotate, 'Girar', _flip),
      _ctrlBtn(_torchOn ? SdIcons.flashlight : SdIcons.lightningSlash,
          'Linterna', _toggleTorch, color: _torchOn ? Sd.amber : Sd.t1, on: _torchOn),
      _ctrlBtn(_talkbackMuted ? SdIcons.speakerSlash : SdIcons.headphones,
          'Retorno', _toggleTalkback, color: _talkbackMuted ? Sd.t3 : Sd.t1),
      _ctrlBtn(SdIcons.stop, 'Detener', _disconnect, color: Sd.red),
    ]),
  );

  Widget _ctrlBtn(IconData icon, String label, VoidCallback fn, {Color color = Sd.t1, bool on = false}) =>
    GestureDetector(
      onTap: fn,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 54, height: 54,
          decoration: BoxDecoration(
            color: on ? Sd.wash(color, 0.18) : const Color(0x99000000),
            shape: BoxShape.circle,
            border: Border.all(color: on ? Sd.wash(color, 0.6) : Sd.borderStrong),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(height: 6),
        Text(label, style: SdText.caption.copyWith(color: color == Sd.t1 ? Sd.t2 : color)),
      ]),
    );

  // ---- Log panel ----
  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Icon(SdIcons.article, size: 20, color: Sd.t2),
            const SizedBox(width: 10),
            const Text('Registro', style: SdText.title),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(SdIcons.copy, size: 16),
              label: const Text('Copiar'),
              onPressed: () => Clipboard.setData(ClipboardData(text: _logs.reversed.join('\n'))),
            ),
          ]),
          const SizedBox(height: 8),
          const Divider(),
          SizedBox(
            height: 360,
            child: _logs.isEmpty
                ? const Center(child: Text('Sin eventos', style: SdText.body))
                : ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText(_logs[i], style: SdText.caption.copyWith(color: Sd.t2, height: 1.4)),
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------
class _OnAirBadge extends StatelessWidget {
  const _OnAirBadge();
  @override
  Widget build(BuildContext context) => const SdPill('EN EL AIRE', color: Sd.red, icon: SdIcons.record, solid: true);
}

class _LegendRow extends StatelessWidget {
  final Color  color;
  final String label;
  final String desc;
  const _LegendRow({required this.color, required this.label, required this.desc});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 5),
          child: Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle))),
      const SizedBox(width: 10),
      SizedBox(width: 44, child: Text(label, style: SdText.label.copyWith(color: color, fontWeight: FontWeight.w600))),
      Expanded(child: Text(desc, style: SdText.label.copyWith(color: Sd.t3))),
    ]),
  );
}

// ---------------------------------------------------------------------------
// QR scanner screen
// ---------------------------------------------------------------------------
class _ScanPage extends StatefulWidget {
  const _ScanPage();
  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Escaneá el QR de SAMBA')),
    body: ReaderWidget(
      cropPercent: 0.9,
      tryHarder: true,
      tryInverted: true,
      scanDelay: const Duration(milliseconds: 400),
      onScan: (code) async {
        if (_done || !code.isValid || code.text == null) return;
        _done = true;
        if (mounted) Navigator.of(context).pop(code.text);
      },
    ),
  );
}

extension _FirstOrNull<E> on List<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
