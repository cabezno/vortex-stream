import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../theme/samba_theme.dart';
import '../../../theme/sd_icons.dart';

/// Microphone of a Studio camera (plan §4, 2026-10-06): the phone's own, a wired headset or a BLUETOOTH headset linked
/// to THIS camera. With one headset per presenter, each camera carries its presenter's voice → the switcher's
/// automatic cut by audio picks the right camera, with less echo and less of the other presenter's voice.
enum MicKind { phone, wired, bluetooth }

class MicChoice {
  final String id;      // flutter_webrtc audioinput deviceId: microphone-<addr> / wired-headset / bluetooth
  final String label;
  final MicKind kind;
  const MicChoice(this.id, this.label, this.kind);

  static const phone = MicChoice('', 'Micrófono del celular', MicKind.phone);

  IconData get icon => switch (kind) {
        MicKind.phone => SdIcons.microphone,
        MicKind.wired => SdIcons.headphones,
        MicKind.bluetooth => SdIcons.bluetooth,
      };

  /// Name sent to the switcher (CamInfoMessage.mic).
  String get infoName => kind == MicKind.phone ? 'phone' : label;
}

class MicPicker {
  MicPicker._();

  /// Inputs Android reports now. The phone's own microphones (often 2–3) are shown as one entry.
  static Future<List<MicChoice>> list() async {
    final out = <MicChoice>[MicChoice.phone];
    try {
      for (final d in await navigator.mediaDevices.enumerateDevices()) {
        if (d.kind != 'audioinput') continue;
        if (d.deviceId == 'bluetooth') {
          out.add(MicChoice('bluetooth', d.label.isNotEmpty ? d.label : 'Auricular Bluetooth', MicKind.bluetooth));
        } else if (d.deviceId == 'wired-headset') {
          out.add(const MicChoice('wired-headset', 'Auricular con cable', MicKind.wired));
        }
      }
    } catch (_) {}
    return out;
  }

  /// Uses [m] for this camera's audio. A Bluetooth headset only records with its voice channel (SCO) open, which
  /// Android opens when it is also the OUTPUT — so it is selected as both (the switcher's return can then be heard
  /// in that ear too). Back to the phone: the loudspeaker route, which closes the headset's channel.
  static Future<void> use(MicChoice m) async {
    try {
      if (m.kind == MicKind.bluetooth) {
        await Helper.selectAudioOutput('bluetooth');
        await Helper.selectAudioInput('bluetooth');
      } else if (m.kind == MicKind.wired) {
        await Helper.selectAudioOutput('wired-headset');
        await Helper.selectAudioInput('wired-headset');
      } else {
        await Helper.selectAudioOutput('speaker');
        final phoneMic = (await navigator.mediaDevices.enumerateDevices())
            .where((d) => d.kind == 'audioinput' && d.deviceId.startsWith('microphone')).firstOrNull;
        if (phoneMic != null) await Helper.selectAudioInput(phoneMic.deviceId);
      }
      debugPrint('[Mic] usando: ${m.label} (${m.kind.name})');
    } catch (e) {
      debugPrint('[Mic] no se pudo cambiar a ${m.label}: $e');
      rethrow;
    }
  }

  /// Sheet to choose the microphone. Returns the choice, or null if dismissed.
  static Future<MicChoice?> show(BuildContext context, MicChoice current) async {
    // Android 12+: seeing a Bluetooth headset needs this permission (asked only here, when it is useful).
    try { await Permission.bluetoothConnect.request(); } catch (_) {}
    final mics = await list();
    if (!context.mounted) return null;
    return showModalBottomSheet<MicChoice>(
      context: context,
      backgroundColor: Sd.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Micrófono de esta cámara', style: SdText.heading),
            const SizedBox(height: 4),
            const Text('Con un auricular por presentador, el corte automático por audio sabe quién habla.',
                style: SdText.caption),
            const SizedBox(height: 12),
            for (final m in mics)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(m.icon, color: m.id == current.id ? Sd.cyan : Sd.t2),
                title: Text(m.label, style: SdText.bodyHi),
                subtitle: Text(switch (m.kind) {
                  MicKind.phone => 'Capta todo el ambiente',
                  MicKind.wired => 'Calidad completa',
                  MicKind.bluetooth => 'Calidad de llamada · suma ~0,1–0,2 s de retraso (se compensa al sincronizar)',
                }, style: SdText.caption),
                trailing: m.id == current.id ? const Icon(SdIcons.check, color: Sd.cyan) : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
            if (!mics.any((m) => m.kind == MicKind.bluetooth)) ...[
              const SizedBox(height: 8),
              const Text('¿Auricular Bluetooth? Vinculalo a ESTE celular desde Ajustes → Bluetooth y aparece acá.',
                  style: SdText.caption),
            ],
          ]),
        ),
      ),
    );
  }
}
