// =============================================================================
// Mode picker — one app, three modes (Samba Air + ex SAMBA Móvil Studio):
//   • Cámara → SAMBA   : the classic Samba Air (SBL / SRT / WHIP / OMT / RTMP to SAMBA desktop)
//   • Cámara → Studio  : this phone is a camera of a phone switcher (WebRTC room, VP8)
//   • Switcher         : this phone hosts the room, switches cameras, records and streams
// The last mode used is remembered and highlighted.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../studio/cam/ui/camera_screen.dart' as studio_cam;
import '../studio/switcher/ui/switcher_screen.dart' as studio_switcher;

class ModePicker extends StatefulWidget {
  final WidgetBuilder sambaHome;   // the classic Samba Air flow (connect → live)
  const ModePicker({super.key, required this.sambaHome});
  @override
  State<ModePicker> createState() => _ModePickerState();
}

class _ModePickerState extends State<ModePicker> {
  static const _prefKey = 'last_mode';
  String? _last;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _last = p.getString(_prefKey));
    });
  }

  Future<void> _open(String mode) async {
    (await SharedPreferences.getInstance()).setString(_prefKey, mode);
    setState(() => _last = mode);
    if (!mounted) return;
    final Widget page = switch (mode) {
      'studio_cam' => _StudioMode(
          keepAliveText: 'Samba Air — cámara de Studio',
          theme: _studioCamTheme,
          child: studio_cam.CameraScreen()),
      'switcher' => _StudioMode(
          keepAliveText: 'Samba Air — switcher',
          theme: _studioSwitcherTheme,
          child: studio_switcher.SwitcherScreen()),
      _ => Builder(builder: widget.sambaHome),
    };
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
          children: [
            const Text('Samba Air',
                style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('¿Qué hace este celular?', style: TextStyle(color: Colors.white60, fontSize: 15)),
            const SizedBox(height: 24),
            _card('samba', Icons.videocam, const Color(0xFF00BBDD), 'Cámara → SAMBA',
                'Transmite a SAMBA en la PC (SBL, SRT, WHIP, OMT o RTMP).'),
            _card('studio_cam', Icons.phone_android, Colors.redAccent, 'Cámara → Studio',
                'Es una cámara de un celular switcher, por Wi-Fi (escaneá su QR).'),
            _card('switcher', Icons.dashboard_customize, Colors.amberAccent, 'Switcher',
                'Recibe las cámaras, corta (a mano o por audio), graba y emite.'),
          ],
        ),
      ),
    );
  }

  Widget _card(String mode, IconData icon, Color color, String title, String subtitle) {
    final last = _last == mode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: const Color(0xFF14141A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: last ? color : Colors.white12, width: last ? 2 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(mode),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              Icon(icon, color: color, size: 40),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 13)),
                ]),
              ),
              if (last) Text('último', style: TextStyle(color: color, fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }
}

// Themes the Studio screens were designed with (their own MaterialApp before the merge).
final _studioCamTheme = ThemeData.dark(useMaterial3: true).copyWith(
  scaffoldBackgroundColor: Colors.black,
  colorScheme: const ColorScheme.dark(primary: Colors.redAccent, secondary: Colors.red),
);
final _studioSwitcherTheme = ThemeData.dark(useMaterial3: true).copyWith(
  scaffoldBackgroundColor: const Color(0xFF0F0F12),
  colorScheme: const ColorScheme.dark(primary: Colors.redAccent, secondary: Colors.amberAccent),
);

// A Studio screen with its own theme, kept alive like a Samba Air live session: foreground service + Wi-Fi/CPU
// locks + screen on (StreamKeepAliveService via the "keepalive" channel). The switcher hosts the room server in
// this process: if Android suspends it, the cameras cannot connect.
class _StudioMode extends StatefulWidget {
  final String keepAliveText;
  final ThemeData theme;
  final Widget child;
  const _StudioMode({required this.keepAliveText, required this.theme, required this.child});
  @override
  State<_StudioMode> createState() => _StudioModeState();
}

class _StudioModeState extends State<_StudioMode> {
  static const _keepAlive = MethodChannel('com.vortex.vortexcam/keepalive');

  @override
  void initState() {
    super.initState();
    _keepAlive.invokeMethod('start', {'text': widget.keepAliveText}).catchError((_) => null);
  }

  @override
  void dispose() {
    _keepAlive.invokeMethod('stop').catchError((_) => null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(data: widget.theme, child: widget.child);
}
