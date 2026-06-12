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
import 'services/log_service.dart';

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
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: const ColorScheme.dark(primary: Color(0xFF00BBDD)),
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF0A0A0A), elevation: 0),
    ),
    home: const _HomePage(),
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _renderer.initialize();
    _loadSaved();
    _log('Samba Air v0.6.0 iniciado');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    Transport.whip => const Color(0xFF00BBDD),
    Transport.srt  => const Color(0xFF34D399),
    Transport.rtmp => const Color(0xFFF59E0B),
    Transport.omt  => const Color(0xFFB57BFF),
    Transport.sbl  => const Color(0xFF7C3AED),
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
    setState(() {
      _config    = cfg;
      _transport = cfg.preferredTransport;
    });
    LogService.instance.configure(host: cfg.host, device: _deviceCtrl.text.trim());

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

  // ---- Manual entry ----
  Future<void> _manualEntry() async {
    final items = <String>['WHIP (WebRTC)', 'SRT', 'RTMP'];
    String selected = _transportLabel;
    final ctrl = TextEditingController();

    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Conexión manual'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: selected,
              items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v) => setState(() => selected = v!),
              decoration: const InputDecoration(labelText: 'Protocolo'),
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
      final parts = url.split(':');
      final ip = parts[0];
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 9000 : 9000;
      cfg = ConnectionConfig.fromSrtIp(ip, port: port);
      t   = Transport.srt;
    } else if (proto.contains('RTMP')) {
      cfg = ConnectionConfig.fromRtmpUrl(url);
      t   = Transport.rtmp;
    } else {
      cfg = ConnectionConfig.fromWhipUrl(url);
      t   = Transport.whip;
    }
    setState(() { _config = cfg; _transport = t; });
    LogService.instance.configure(host: cfg.host, device: _deviceCtrl.text.trim());
    _log('Manual: $proto → $url');
  }

  String _urlLabel(String proto) {
    if (proto.contains('SRT'))  return 'IP:puerto (ej. 192.168.1.2:9000)';
    if (proto.contains('RTMP')) return 'rtmp://ip/app/clave';
    return 'http://ip:8080/whip/';
  }
  String _urlHint(String proto) {
    if (proto.contains('SRT'))  return '192.168.137.1:9000';
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

    setState(() => _connecting = true);
    try {
      if (!(await Permission.camera.request()).isGranted) {
        _log('Permiso de cámara denegado'); return;
      }
      await Permission.microphone.request();
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
      name:    _deviceCtrl.text.trim().isEmpty ? 'SambaAir' : _deviceCtrl.text.trim(),
    );

    try {
      await omt.start(port: port);
      setState(() { _live = true; });
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
    await sbl.configure(
      width:            cfg.video.width,
      height:           cfg.video.height,
      targetBitrateBps: cfg.video.maxKbps * 1000,
    );
    try {
      await sbl.startCamera(frontCamera: _frontCam);
      _nativeTexId = sbl.textureId;
      await sbl.connect(
        sblCfg.host,
        port:       sblCfg.port,
        sourceName: _deviceCtrl.text.trim().isEmpty ? 'SambaAir' : _deviceCtrl.text.trim(),
      );
      setState(() { _live = true; });
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

  // ---- Disconnect ----
  Future<void> _disconnect() async {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    setState(() { _live = false; _onAir = false; });

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
        await context.read<SrtConnectionService>()
            .connectTo('', port: 0);  // stub — flip via plugin
      case Transport.rtmp:
        await context.read<RtmpConnectionService>().flipCamera();
      case Transport.omt:
        break; // camera flip handled internally by OmtStreamPlugin
      case Transport.sbl:
        break;
    }
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Samba Air'),
        actions: [
          IconButton(tooltip: 'Registro', icon: const Icon(Icons.article_outlined), onPressed: _showLogs),
        ],
      ),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

          // Status card
          if (_config != null) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _transportColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _transportColor.withOpacity(0.3)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.check_circle, color: _transportColor, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    '${_config!.host}  •  $_transportLabel',
                    style: TextStyle(color: _transportColor, fontWeight: FontWeight.w600),
                  )),
                ]),
                // WiFi status row (only when hotspot credentials present)
                if (_config!.hasWifi) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    if (_wifiConnecting)
                      const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      Icon(
                        _wifiStatus.startsWith('✓') ? Icons.wifi : Icons.wifi_off,
                        size: 14,
                        color: _wifiStatus.startsWith('✓') ? Colors.green : Colors.orange,
                      ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      _wifiStatus.isEmpty ? 'WiFi: ${_config!.wifi!.ssid}' : _wifiStatus,
                      style: TextStyle(
                        fontSize: 12,
                        color: _wifiStatus.startsWith('✓') ? Colors.green : Colors.orange[300],
                      ),
                    )),
                  ]),
                ],
              ]),
            ),
            const SizedBox(height: 12),
          ],

          // Camera name
          TextField(
            controller: _deviceCtrl,
            decoration: const InputDecoration(
              labelText: 'Nombre de cámara',
              hintText: 'cam1',
              border: OutlineInputBorder(),
              isDense: true,
              prefixIcon: Icon(Icons.videocam_outlined),
            ),
          ),
          const SizedBox(height: 12),

          // Transport selector (only when multiple options available)
          if (_config != null && _transportOptions.length > 1)
            _buildTransportPicker(),

          const SizedBox(height: 12),

          // QR + Go live
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: (configured && !_connecting && !_wifiConnecting) ? _connect : null,
                icon: _connecting
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.videocam),
                label: Text(_wifiConnecting ? 'Conectando WiFi...' : _connecting ? 'Conectando...' : 'Go live  $_transportLabel'),
                style: FilledButton.styleFrom(backgroundColor: _transportColor),
              ),
            ),
          ]),

          TextButton.icon(
            onPressed: _manualEntry,
            icon: const Icon(Icons.keyboard, size: 18),
            label: const Text('Ingresar manualmente'),
          ),

          const Spacer(),

          // Transport legend
          _buildTransportLegend(),
        ]),
      )),
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

  Widget _buildTransportPicker() => Container(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Transporte', style: TextStyle(color: Colors.white54, fontSize: 12)),
      const SizedBox(height: 6),
      Row(children: _transportOptions.map((t) {
        final active = _transport == t;
        final color  = colorFor(t);
        final label  = labelFor(t);
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => setState(() => _transport = t),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color:        active ? color.withOpacity(0.2) : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: active ? color : Colors.white24),
              ),
              child: Text(label,
                style: TextStyle(
                  color:      active ? color : Colors.white54,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  fontSize:   13,
                )),
            ),
          ),
        );
      }).toList()),
    ]),
  );

  Widget _buildTransportLegend() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: const [
      Divider(),
      SizedBox(height: 4),
      _LegendRow(color: Color(0xFF7C3AED), label: 'SBL',  desc: 'LAN, H.264, protocolo nativo SAMBA'),
      _LegendRow(color: Color(0xFFB57BFF), label: 'OMT',  desc: 'LAN, VMX 4:2:2, ~16ms, máxima calidad'),
      _LegendRow(color: Color(0xFF34D399), label: 'SRT',  desc: 'LAN, H.265, baja latencia'),
      _LegendRow(color: Color(0xFF00BBDD), label: 'WHIP', desc: 'LAN + internet, H.264, WebRTC'),
      _LegendRow(color: Color(0xFFF59E0B), label: 'RTMP', desc: 'LAN + internet, H.264, compatible'),
    ],
  );

  // -----------------------------------------------------------------------
  // Live view
  // -----------------------------------------------------------------------
  Widget _buildLiveView() {
    // Stats per transport
    double bitrate = 0;
    int    latency = 0;
    bool   onAir   = _onAir;

    switch (_transport) {
      case Transport.whip:
        final conn = context.watch<ConnectionService>();
        latency = conn.latencyMs;
        onAir   = conn.isOnAir;
      case Transport.srt:
        final srt = context.watch<SrtConnectionService>();
        bitrate = srt.bitrateMbps;
        latency = srt.latencyMs;
        onAir   = srt.isOnAir;
      case Transport.rtmp:
        final rtmp = context.watch<RtmpConnectionService>();
        bitrate = rtmp.bitrateMbps;
        latency = rtmp.latencyMs;
      case Transport.omt:
        final omt = context.watch<OmtConnectionService>();
        bitrate = omt.mbpsSent;
        onAir   = omt.connected;
      case Transport.sbl:
        final sbl = context.watch<SblConnectionService>();
        bitrate = sbl.mbpsSent;
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
            ? Texture(textureId: texId)
            : const Center(child: CircularProgressIndicator());
      case Transport.omt:
        // OMT uses Camera2 directly in native code — show status overlay
        final omt = context.watch<OmtConnectionService>();
        preview = Container(
          color: Colors.black,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.videocam,
                  size: 64,
                  color: omt.connected ? const Color(0xFFB57BFF) : Colors.white24),
              const SizedBox(height: 12),
              Text(
                omt.connected ? 'OMT — VortexEngine conectado' : 'OMT — esperando receptor...',
                style: TextStyle(
                  color: omt.connected ? const Color(0xFFB57BFF) : Colors.white38,
                  fontSize: 14,
                ),
              ),
              if (omt.isStreaming) ...[
                const SizedBox(height: 8),
                Text('Puerto :${omt.listenPort}   ${omt.mbpsSent.toStringAsFixed(1)} Mbps',
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
                Text('${omt.framesSent} frames enviados',
                    style: const TextStyle(color: Colors.white24, fontSize: 11)),
              ],
            ]),
          ),
        );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showCtrl = !_showCtrl),
        child: Stack(fit: StackFit.expand, children: [
          preview,

          // Tally: full screen red pulse when ON AIR
          if (onAir)
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: 0.12,
                duration: const Duration(milliseconds: 300),
                child: Container(color: Colors.red),
              ),
            ),

          // ON AIR badge
          if (onAir)
            const Positioned(top: 48, left: 16, child: _OnAirBadge()),

          // Transport + stats (top-right)
          Positioned(
            top: 44,
            right: 16,
            child: _statsBar(bitrate, latency, _transportLabel, _transportColor),
          ),

          // Log button
          Positioned(
            top: 4, right: 4,
            child: IconButton(
              icon: const Icon(Icons.article_outlined, size: 16, color: Colors.white24),
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

  Widget _statsBar(double bitMbps, int latMs, String proto, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 7, height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Text(proto, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
      const SizedBox(width: 8),
      if (bitMbps > 0)
        Text('${bitMbps.toStringAsFixed(1)} Mbps',
            style: const TextStyle(color: Colors.white70, fontSize: 11)),
      if (latMs > 0) ...[
        const SizedBox(width: 4),
        Text('${latMs}ms',
            style: const TextStyle(color: Colors.white38, fontSize: 10)),
      ],
    ]),
  );

  Widget _controlBar() => Container(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [Colors.black87, Colors.transparent],
      ),
    ),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      _ctrlBtn(_frontCam ? Icons.camera_front : Icons.camera_rear, 'Flip', _flip),
      _ctrlBtn(
        _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
        'Linterna', _toggleTorch,
        color: _torchOn ? Colors.yellow : Colors.white,
      ),
      _ctrlBtn(Icons.link_off, 'Detener', _disconnect, color: Colors.red.shade400),
    ]),
  );

  Widget _ctrlBtn(IconData icon, String label, VoidCallback fn, {Color color = Colors.white}) =>
    GestureDetector(
      onTap: fn,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: color.withOpacity(0.8), fontSize: 10)),
      ]),
    );

  // ---- Log panel ----
  void _showLogs() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF101418),
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Text('Registro', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copiar'),
              onPressed: () => Clipboard.setData(ClipboardData(text: _logs.reversed.join('\n'))),
            ),
          ]),
          const Divider(height: 8),
          SizedBox(
            height: 360,
            child: _logs.isEmpty
                ? const Center(child: Text('Sin eventos', style: TextStyle(color: Colors.white38)))
                : ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: SelectableText(_logs[i],
                          style: const TextStyle(fontSize: 11, color: Colors.white60)),
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      CircleAvatar(radius: 4, backgroundColor: Colors.white),
      SizedBox(width: 6),
      Text('ON AIR',
        style: TextStyle(color: Colors.white, fontSize: 12,
            fontWeight: FontWeight.w800, letterSpacing: 1)),
    ]),
  );
}

class _LegendRow extends StatelessWidget {
  final Color  color;
  final String label;
  final String desc;
  const _LegendRow({required this.color, required this.label, required this.desc});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 8),
      Text('$label — ', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
      Text(desc, style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
    appBar: AppBar(title: const Text('Escaneá el QR de VortexEngine')),
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
