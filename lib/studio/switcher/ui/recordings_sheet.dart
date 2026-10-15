import 'package:flutter/material.dart';
import '../../../theme/samba_theme.dart';
import '../output/recordings.dart';

/// The switcher's recordings (Movies/Samba Air): tap to watch in the phone's player, share to send them.
class RecordingsSheet {
  static Future<void> show(BuildContext context) async {
    var items = await Recordings.list().catchError((_) => <Recording>[]);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Sd.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> run(Future<bool> Function() action) async {
          if (!await action() && ctx.mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                content: Text('No hay ninguna app para abrirla. Está en la carpeta Movies/Samba Air del celular.')));
          }
        }

        return SafeArea(child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Grabaciones', style: SdText.heading)),
                IconButton(
                  tooltip: 'Actualizar',
                  icon: const Icon(Icons.refresh),
                  onPressed: () async { final l = await Recordings.list(); setSheet(() => items = l); },
                ),
              ]),
              const Text('En la Galería, carpeta Movies/Samba Air.', style: SdText.caption),
              const SizedBox(height: 8),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Todavía no hay grabaciones.', style: SdText.body),
                )
              else
                Flexible(child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final r = items[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.play_circle_outline, color: Sd.cyan, size: 32),
                      title: Text(_when(r.date), style: SdText.bodyHi),
                      subtitle: Text('${_dur(r.ms)} · ${_size(r.bytes)}', style: SdText.caption),
                      trailing: IconButton(
                        tooltip: 'Compartir',
                        icon: const Icon(Icons.share_outlined),
                        onPressed: () => run(() => Recordings.share(r.uri)),
                      ),
                      onTap: () => run(() => Recordings.open(r.uri)),
                    );
                  },
                )),
            ]),
          ),
        ));
      }),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _when(DateTime d) => '${_two(d.day)}/${_two(d.month)} ${_two(d.hour)}:${_two(d.minute)}';
  static String _dur(int ms) {
    if (ms <= 0) return 'duración desconocida';
    final s = ms ~/ 1000;
    return s >= 3600 ? '${s ~/ 3600}:${_two(s % 3600 ~/ 60)}:${_two(s % 60)}' : '${s ~/ 60}:${_two(s % 60)}';
  }
  static String _size(int b) =>
      b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : '${(b / (1 << 20)).toStringAsFixed(0)} MB';
}
