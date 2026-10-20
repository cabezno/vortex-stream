import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// One switcher recording in the gallery (Movies/Samba Air).
class Recording {
  final String uri, name;
  final int bytes, ms;
  final DateTime date;
  Recording(Map m)
      : uri = m['uri'] as String,
        name = m['name'] as String? ?? '',
        bytes = (m['bytes'] as num?)?.toInt() ?? 0,
        ms = (m['ms'] as num?)?.toInt() ?? 0,
        date = DateTime.fromMillisecondsSinceEpoch(((m['date'] as num?)?.toInt() ?? 0) * 1000);
}

/// The switcher's recordings, on the native side (RecordingsStore.kt): moved into the gallery when they finish, listed,
/// opened in the phone's player and shared. Before 2026-10-15 they stayed in the app's private folder, out of reach.
class Recordings {
  static const _ch = MethodChannel('com.samba.studio/recordings');

  /// Moves a finished file into the gallery; returns its uri, or null if it could not (the file stays where it was).
  static Future<String?> publish(String path) async {
    try {
      return await _ch.invokeMethod<String>('publish', {'path': path});
    } catch (e) {
      debugPrint('[Recordings] no se pudo pasar a la galería $path: $e');
      return null;
    }
  }

  static Future<List<Recording>> list() async {
    final l = await _ch.invokeListMethod<Map>('list') ?? const [];
    return l.map(Recording.new).toList();
  }

  static Future<bool> open(String uri) async => await _ch.invokeMethod<bool>('open', {'uri': uri}) ?? false;
  static Future<bool> share(String uri) async => await _ch.invokeMethod<bool>('share', {'uri': uri}) ?? false;

  /// Recordings left in the private folder (made before this fix, or a stop that never got to publish): move them
  /// to the gallery so an uninstall doesn't take them. [except] = the file being recorded right now. Returns how many.
  static Future<int> rescueOrphans({String? except}) async {
    var n = 0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final f in dir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.startsWith('SAMBA_REC_') || !name.endsWith('.mp4') || f.path == except) continue;
        if (f.lengthSync() == 0) { f.deleteSync(); continue; }
        if (await publish(f.path) != null) n++;
      }
    } catch (e) {
      debugPrint('[Recordings] rescate: $e');
    }
    return n;
  }
}
