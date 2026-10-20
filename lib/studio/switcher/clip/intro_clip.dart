import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The intro video (2026-10-20): a clip from the phone that opens the live stream and/or the recording, then fades to
/// the cameras on its own. The native side (ClipPlayer) puts it in the program — picture and sound — and gives a
/// texture for the monitor here.
class IntroClip extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('com.samba.studio/program_encoder');

  IntroClip() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'clipEnded') _ended();
    });
    _load();
  }

  // ── Settings (kept) ─────────────────────────────────────────────────────────────────────────────────────────
  String? path;            // the app's own copy of the chosen video
  String? name;            // its original file name, to show
  bool onStream = true;    // when going live
  bool onRecord = true;    // when starting a recording
  bool fill = false;       // a clip of another shape: cropped to fill (true) or whole with bars

  bool get hasClip => path != null && File(path!).existsSync();

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      path = p.getString('intro.path');
      name = p.getString('intro.name');
      onStream = p.getBool('intro.onStream') ?? true;
      onRecord = p.getBool('intro.onRecord') ?? true;
      fill = p.getBool('intro.fill') ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> save() async {
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      if (path == null) { await p.remove('intro.path'); await p.remove('intro.name'); }
      else { await p.setString('intro.path', path!); await p.setString('intro.name', name ?? ''); }
      await p.setBool('intro.onStream', onStream);
      await p.setBool('intro.onRecord', onRecord);
      await p.setBool('intro.fill', fill);
    } catch (_) {}
  }

  bool picking = false;

  /// Lets the user choose a video; it is copied into the app (the gallery's copy may move or go). False = cancelled.
  Future<bool> pick() async {
    picking = true; notifyListeners();
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.video);
      final src = r?.files.single.path;
      if (src == null) return false;
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/intro');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final ext = src.contains('.') ? src.substring(src.lastIndexOf('.')) : '.mp4';
      final dst = '${dir.path}/intro$ext';
      await File(src).copy(dst);
      try { await File(src).delete(); } catch (_) {}      // file_picker's temporary copy
      path = dst;
      name = r!.files.single.name;
      await save();
      return true;
    } finally {
      picking = false; notifyListeners();
    }
  }

  Future<void> clear() async {
    await stop();
    try { if (path != null) await File(path!).delete(); } catch (_) {}
    path = null; name = null;
    await save();
  }

  // ── Playing ─────────────────────────────────────────────────────────────────────────────────────────────────
  /// The clip is in the program (from prepare until its fade ends).
  bool get isOn => textureId != null;
  /// Fading out to the cameras.
  bool ending = false;
  int? textureId;
  double aspect = 16 / 9;
  Duration duration = Duration.zero;
  DateTime? startedAt;
  String? lastError;

  /// Whether starting this output should open with the clip (only when nothing was going out yet).
  bool wants({required bool stream}) => hasClip && !isOn && (stream ? onStream : onRecord);

  /// Puts the clip in the program, black and silent until [play]. False when it cannot be played.
  Future<bool> prepare() async {
    lastError = null;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('clipPrepare', {'path': path, 'fill': fill});
      if (r == null) return false;
      final w = (r['width'] as num?)?.toDouble() ?? 0, h = (r['height'] as num?)?.toDouble() ?? 0;
      aspect = w > 0 && h > 0 ? w / h : 16 / 9;
      duration = Duration(milliseconds: (r['durationMs'] as num?)?.toInt() ?? 0);
      textureId = (r['textureId'] as num?)?.toInt() ?? -1;
      ending = false;
      startedAt = null;
      notifyListeners();
      return true;
    } catch (e) {
      lastError = e is PlatformException ? (e.message ?? e.code) : '$e';
      debugPrint('[IntroClip] $lastError');
      textureId = null;
      notifyListeners();
      return false;
    }
  }

  Future<void> play() async {
    if (!isOn) return;
    startedAt = DateTime.now();
    notifyListeners();
    try { await _channel.invokeMethod('clipPlay'); } catch (_) {}
  }

  /// «Saltar»: fade to the cameras now.
  Future<void> skip() async {
    try { await _channel.invokeMethod('clipSkip'); } catch (_) {}
  }

  /// Out of the program at once (the output stopped).
  Future<void> stop() async {
    if (!isOn) return;
    try { await _channel.invokeMethod('clipStop'); } catch (_) {}
    _ended();
  }

  void _ended() {
    if (!isOn || ending) return;
    ending = true;
    notifyListeners();
    // The monitor fades with the program, then the texture is gone.
    Future.delayed(const Duration(milliseconds: 550), () {
      textureId = null; ending = false; startedAt = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _channel.invokeMethod('clipStop').catchError((_) => null);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
