import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

// =============================================================================
// LogService — buffers app log lines, persists them to a local file, and ships
// them to the PC (SAMBA engine) so they can be analysed locally.
//
// The log travels to the PC:
//   - on demand (shipToPc),
//   - when the camera/connection closes (_disconnect),
//   - when the app is backgrounded/closed (app lifecycle paused/detached),
//   - on an uncaught error / FlutterError (crash capture in main()).
//
// Engine side: POST http://{host}:{port}/phonelog?source=..&reason=..
//   handled by WHIPServer (whip_server.cpp) → saved to
//   %APPDATA%\Samba\phone_logs\<source>_<timestamp>.log
//
// All network/file work is best-effort and never throws to the caller.
// =============================================================================
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  final List<String> _buffer = [];
  String _engineHost = '';
  int    _enginePort = 8080;
  String _device     = 'cam1';
  File?  _file;
  bool   _shipping   = false;

  bool get hasTarget => _engineHost.isNotEmpty;

  // Set the PC target (called when a QR/manual config is selected).
  void configure({required String host, int port = 8080, String device = 'cam1'}) {
    _engineHost = host;
    _enginePort = port;
    if (device.trim().isNotEmpty) _device = device.trim();
  }

  // Open the local log file. Truncates at session start to bound growth.
  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/sambaair.log');
      await _file!.writeAsString(
        '=== Samba Air — ${DateTime.now().toIso8601String()} ===\n',
      );
    } catch (_) {/* file logging is optional */}
  }

  // Append a line to the in-memory buffer and (best-effort) the file.
  void add(String line) {
    _buffer.add(line);
    if (_buffer.length > 3000) _buffer.removeRange(0, _buffer.length - 3000);
    final f = _file;
    if (f != null) {
      f.writeAsString('$line\n', mode: FileMode.append, flush: false)
       .catchError((_) => f);
    }
  }

  String dump() => _buffer.join('\n');

  // POST the buffered log to the PC. Best-effort, short timeout, never throws.
  Future<bool> shipToPc({String reason = 'manual'}) async {
    if (_shipping || _engineHost.isEmpty || _buffer.isEmpty) return false;
    _shipping = true;
    try {
      final uri = Uri.parse(
        'http://$_engineHost:$_enginePort/phonelog'
        '?source=${Uri.encodeComponent(_device)}'
        '&reason=${Uri.encodeComponent(reason)}',
      );
      final body = StringBuffer()
        ..writeln('# Samba Air log — reason=$reason — ${DateTime.now().toIso8601String()}')
        ..writeln('# device=$_device  host=$_engineHost:$_enginePort')
        ..writeln(dump());
      final r = await http
          .post(uri,
              headers: {'Content-Type': 'text/plain; charset=utf-8'},
              body: body.toString())
          .timeout(const Duration(seconds: 4));
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      _shipping = false;
    }
  }
}
