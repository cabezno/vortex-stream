// =============================================================================
// Mode picker — one app, what the PHONE does (Samba Air + ex SAMBA Móvil Studio):
//   • Cámara   → then the destination:
//        – SAMBA (PC)          : the classic Samba Air (SBL / SRT / WHIP / OMT / RTMP to SAMBA desktop)
//        – Switcher (celular)  : camera of a phone switcher (WebRTC room, VP8)
//   • Switcher : hosts the room, switches cameras (manual / by audio), records and streams (platforms or SAMBA)
// The last choice at each level is remembered and highlighted.
// =============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/sd_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/samba_theme.dart';
import '../studio/cam/ui/camera_screen.dart' as studio_cam;
import '../studio/switcher/ui/switcher_screen.dart' as studio_switcher;

class ModePicker extends StatefulWidget {
  final WidgetBuilder sambaHome;   // the classic Samba Air flow (connect → live)
  const ModePicker({super.key, required this.sambaHome});
  @override
  State<ModePicker> createState() => _ModePickerState();
}

class _ModePickerState extends State<ModePicker> {
  static const _prefKey = 'last_mode';        // 'camera' | 'switcher'
  static const _prefDest = 'last_camera_dest'; // 'samba' | 'studio_cam'
  String? _last, _lastDest;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() { _last = p.getString(_prefKey); _lastDest = p.getString(_prefDest); });
    });
  }

  Future<void> _remember(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);

  Future<void> _pick(String mode) async {
    _remember(_prefKey, mode);
    setState(() => _last = mode);
    if (mode == 'switcher') return _open('switcher');
    // Cámara → choose where it sends
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _Chooser(
      title: 'Cámara',
      subtitle: '¿A dónde manda este celular?',
      last: _lastDest,
      options: const [
        _Option('samba', SdIcons.desktop, Sd.cyan, 'SAMBA (PC)',
            'Transmite a SAMBA en la computadora: SBL, SRT, WHIP, OMT o RTMP.'),
        _Option('studio_cam', SdIcons.deviceMobile, Sd.magenta, 'Switcher (celular)',
            'Es una cámara de un celular switcher, por Wi-Fi (escaneá su QR).'),
      ],
      onPick: (dest) { _remember(_prefDest, dest); setState(() => _lastDest = dest); _open(dest); },
    )));
  }

  Future<void> _open(String mode) async {
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
  Widget build(BuildContext context) => _Chooser(
        title: 'Samba Air',
        subtitle: '¿Qué hace este celular?',
        last: _last,
        options: const [
          _Option('camera', SdIcons.videoCamera, Sd.cyan, 'Cámara',
              'Filma y transmite: a SAMBA en la PC o a un celular switcher.'),
          _Option('switcher', SdIcons.squaresFour, Sd.magenta, 'Switcher',
              'Recibe las cámaras, corta (a mano o por audio), graba y emite a plataformas o a SAMBA.'),
        ],
        onPick: _pick,
      );
}

class _Option {
  final String id; final IconData icon; final Color color; final String title, subtitle;
  const _Option(this.id, this.icon, this.color, this.title, this.subtitle);
}

// A full-screen list of big option cards; the last one used is outlined.
class _Chooser extends StatelessWidget {
  final String title, subtitle;
  final String? last;
  final List<_Option> options;
  final void Function(String id) onPick;
  const _Chooser({required this.title, required this.subtitle, required this.last,
                  required this.options, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: Sd.void_,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Row(children: [
              if (canPop)
                IconButton(
                  icon: const Icon(SdIcons.arrowLeft),
                  onPressed: () => Navigator.of(context).maybePop(),
                  padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
                ),
              Text('SAMBA', style: SdText.overline.copyWith(color: Sd.cyan, letterSpacing: 2.4)),
            ]),
            const SizedBox(height: 14),
            Text(title, style: SdText.display),
            const SizedBox(height: 6),
            Text(subtitle, style: SdText.body),
            const SizedBox(height: 28),
            for (final o in options) _card(o),
          ],
        ),
      ),
    );
  }

  Widget _card(_Option o) {
    final isLast = last == o.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // One stable label for screen readers (and UI tests): title + description, whatever badge is shown.
      child: Semantics(
        button: true,
        label: '${o.title} ${o.subtitle}',
        excludeSemantics: true,
        child: Material(
        color: Sd.raised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Sd.r2),
          side: BorderSide(color: isLast ? Sd.wash(o.color, 0.55) : Sd.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Sd.r2),
          splashColor: Sd.wash(o.color, 0.10),
          highlightColor: Sd.wash(o.color, 0.05),
          onTap: () => onPick(o.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 18),
            child: Row(children: [
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: Sd.wash(o.color, 0.10),
                  shape: BoxShape.circle,
                  border: Border.all(color: Sd.wash(o.color, 0.30)),
                ),
                child: Icon(o.icon, color: o.color, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(o.title, style: SdText.heading.copyWith(fontSize: 17)),
                    if (isLast) ...[const SizedBox(width: 10), SdPill('ÚLTIMO', color: o.color)],
                  ]),
                  const SizedBox(height: 5),
                  Text(o.subtitle, style: SdText.body.copyWith(fontSize: 13)),
                ]),
              ),
              const SizedBox(width: 8),
              const Icon(SdIcons.caretRight, color: Sd.t3, size: 18),
            ]),
          ),
        ),
      ),
      ),
    );
  }
}

// Themes the Studio screens were designed with (their own MaterialApp before the merge).
// (Now the same SAMBA theme for every mode.)
final _studioCamTheme = sambaTheme();
final _studioSwitcherTheme = sambaTheme();

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
