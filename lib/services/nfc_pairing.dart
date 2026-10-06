import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Pair a camera by touching the switcher with it (NFC, 2026-10-06; native side: NfcPairing.kt).
/// The switcher advertises its QR JSON as an NFC card; a camera on its join screen reads it and follows the same
/// path as a scanned QR (join the switcher's own network if any, then the room).
class NfcPairing {
  NfcPairing._();
  static const _ch = MethodChannel('com.vortex.vortexcam/native');
  static void Function(String json)? _onPayload;
  static bool _handlerSet = false;

  /// {available: phone has NFC, enabled: switched on in Settings}.
  static Future<({bool available, bool enabled})> info() async {
    try {
      final m = Map<String, dynamic>.from(await _ch.invokeMethod<Map>('nfcInfo') ?? const {});
      return (available: m['available'] == true, enabled: m['enabled'] == true);
    } catch (_) {
      return (available: false, enabled: false);
    }
  }

  /// Switcher: what a camera gets when it touches this phone (null stops advertising).
  static Future<void> advertise(String? json) async {
    try { await _ch.invokeMethod('nfcSetPayload', {'json': json}); } catch (_) {}
  }

  /// Camera: read a switcher when touched; [onPayload] gets its pairing JSON.
  static Future<bool> listen(void Function(String json) onPayload) async {
    _onPayload = onPayload;
    if (!_handlerSet) {
      _handlerSet = true;
      _ch.setMethodCallHandler((call) async {
        if (call.method == 'nfcPayload' && call.arguments is String) {
          debugPrint('[NFC] emparejamiento leído');
          _onPayload?.call(call.arguments as String);
        }
        return null;
      });
    }
    try { return await _ch.invokeMethod<bool>('nfcStartReader') ?? false; } catch (_) { return false; }
  }

  static Future<void> stopListening() async {
    _onPayload = null;
    try { await _ch.invokeMethod('nfcStopReader'); } catch (_) {}
  }

  static Future<void> openSettings() async {
    try { await _ch.invokeMethod('openNfcSettings'); } catch (_) {}
  }
}
