import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/samba_theme.dart';
import '../../theme/sd_icons.dart';

/// Which camera a Studio source films with (plan §6, 2026-10-06): the phone's back / front cameras or an EXTERNAL
/// one — a USB camera or an HDMI capture dongle (UVC) plugged into the phone. Android only shows external cameras on
/// phones whose maker enabled them (FEATURE_CAMERA_EXTERNAL); the picker says so instead of just not listing them.
class CameraChoice {
  final String id;        // Camera2 id = getUserMedia deviceId
  final String facing;    // back / front / external
  final String? max;      // largest 16:9 size, e.g. 3840x2160
  const CameraChoice(this.id, this.facing, this.max);

  bool get external => facing == 'external';
  String get label => switch (facing) {
        'back' => 'Trasera',
        'front' => 'Frontal',
        _ => 'Cámara USB / HDMI',
      };
  IconData get icon => external ? SdIcons.usb : facing == 'front' ? SdIcons.userFocus : SdIcons.camera;
}

class CameraPicker {
  CameraPicker._();
  static const _native = MethodChannel('com.vortex.vortexcam/native');

  static Future<({List<CameraChoice> cameras, bool externalSupported})> list() async {
    try {
      final r = Map<String, dynamic>.from(await _native.invokeMethod<Map>('listCameras') ?? const {});
      final cams = ((r['cameras'] as List?) ?? const []).map((c) {
        final m = Map<String, dynamic>.from(c as Map);
        return CameraChoice(m['id'] as String, m['facing'] as String? ?? 'back', m['max'] as String?);
      }).toList();
      return (cameras: cams, externalSupported: r['externalSupported'] == true);
    } catch (e) {
      debugPrint('[CameraPicker] $e');
      return (cameras: <CameraChoice>[], externalSupported: false);
    }
  }

  /// Sheet to choose the camera. Returns the choice, or null if dismissed. [currentId]: the one in use (if known).
  static Future<CameraChoice?> show(BuildContext context, {String? currentId}) async {
    var r = await list();
    if (!context.mounted) return null;
    return showModalBottomSheet<CameraChoice>(
      context: context,
      backgroundColor: Sd.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final ext = r.cameras.where((c) => c.external).toList();
        // Phones often expose several back lenses (wide, ultra-wide…): keep them, numbered.
        int n = 0;
        return SafeArea(child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Cámara', style: SdText.heading)),
              IconButton(
                tooltip: 'Buscar de nuevo (recién enchufada)',
                icon: const Icon(SdIcons.arrowsClockwise),
                onPressed: () async { final nr = await list(); setSheet(() => r = nr); },
              ),
            ]),
            for (final c in r.cameras)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(c.icon, color: c.id == currentId ? Sd.cyan : Sd.t2),
                title: Text(c.facing == 'back' && r.cameras.where((x) => x.facing == 'back').length > 1
                    ? '${c.label} ${++n}' : c.label, style: SdText.bodyHi),
                subtitle: Text(c.max != null ? 'hasta ${c.max}' : '', style: SdText.caption),
                trailing: c.id == currentId ? const Icon(SdIcons.check, color: Sd.cyan) : null,
                onTap: () => Navigator.pop(ctx, c),
              ),
            const SizedBox(height: 8),
            if (ext.isEmpty)
              Text(r.externalSupported
                  ? 'Para usar una cámara USB o una capturadora HDMI: enchufala al celular (con un adaptador OTG si '
                    'hace falta) y tocá buscar de nuevo.'
                  : 'Este celular no reconoce cámaras USB ni capturadoras HDMI: su fabricante no activó esa función '
                    'de Android.', style: SdText.caption),
          ]),
        ));
      }),
    );
  }
}
