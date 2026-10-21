import 'package:flutter/foundation.dart';

/// Native libraries bundled in the APK that Flutter's license page does not know about (it only lists Dart packages).
/// Shown with the rest in «Licencias» (mode picker).
void registerNativeLicenses() {
  LicenseRegistry.addLicense(() => Stream.fromIterable(const [
    LicenseEntryWithLineBreaks(['libsrt (SRT)'], '''
Secure Reliable Transport (SRT) 1.5 — Haivision Systems Inc. and contributors.
Mozilla Public License 2.0 (MPL-2.0): https://mozilla.org/MPL/2.0/
Source code: https://github.com/Haivision/srt
Used unmodified, through srtdroid, for the «SRT» transport of Cámara → SAMBA.'''),
    LicenseEntryWithLineBreaks(['srtdroid'], '''
srtdroid 1.9.1 — Copyright ThibaultBee.
Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0
Source code: https://github.com/ThibaultBee/srtdroid'''),
  ]));
}
