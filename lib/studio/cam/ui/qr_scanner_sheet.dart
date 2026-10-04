import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';  // ZXing via FFI, no ML Kit (like the rest of Samba Air)
import 'package:samba_protocol/samba_protocol.dart';

class QrScannerSheet extends StatefulWidget {
  final void Function(PairingPayload payload) onScanned;

  const QrScannerSheet({super.key, required this.onScanned});

  static Future<void> show(
    BuildContext context, {
    required void Function(PairingPayload payload) onScanned,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => QrScannerSheet(onScanned: onScanned),
    );
  }

  @override
  State<QrScannerSheet> createState() => _QrScannerSheetState();
}

class _QrScannerSheetState extends State<QrScannerSheet> {
  bool _hasDetected = false;

  void _onScan(Code code) {
    if (_hasDetected) return;
    final rawValue = code.text;
    if (code.isValid && rawValue != null && rawValue.trim().isNotEmpty) {
      _hasDetected = true;
      final payload = PairingPayload.parse(rawValue);
      widget.onScanned(payload);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Escanear QR del Switcher',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                ReaderWidget(
                  cropPercent: 0.9,
                  tryHarder: true,
                  tryInverted: true,
                  scanDelay: const Duration(milliseconds: 400),
                  onScan: (code) async => _onScan(code),
                ),
                Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.redAccent, width: 3),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Apunta la cámara hacia el código QR mostrado en la pantalla del Switcher',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
