import 'package:flutter/material.dart';
import '../../../theme/sd_icons.dart';
import '../../../theme/samba_theme.dart';
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
      backgroundColor: Sd.raised,
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
                const Text('Escanear el QR del switcher', style: SdText.title),
                IconButton(
                  icon: const Icon(SdIcons.x),
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
                      border: Border.all(color: Sd.magenta, width: 1.5),
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Apuntá la cámara al QR que muestra la pantalla del switcher.',
              textAlign: TextAlign.center,
              style: SdText.body,
            ),
          ),
        ],
      ),
    );
  }
}
