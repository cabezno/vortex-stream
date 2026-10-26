"""flutter_webrtc opens the mic in STEREO when bypassVoiceProcessing is on (the app's «Sonido natural»): in
MethodCallHandlerImpl.initialize, setUseStereoInput(true). On a phone with one microphone that comes out as digital
silence: the Galaxy A10 sent SAMBA −108 dB by WHIP with a tone playing, while SRT/SBL (mono) carried it (DT-315,
2026-10-26). This turns it into setUseStereoInput(false) in the pub-cache copy of the resolved version. Run from the
Flutter project root after `flutter pub get`. Fails if the line is not there: a new flutter_webrtc must be looked at,
not built silently with the stereo mic."""
import os, re, sys

lock = open("pubspec.lock", encoding="utf-8").read()
m = re.search(r"\n  flutter_webrtc:\n(?:    .*\n)*?    version: \"([^\"]+)\"", lock)
if not m:
    sys.exit("flutter_webrtc not in pubspec.lock")
ver = m.group(1)
caches = [os.environ.get("PUB_CACHE"), os.path.expanduser("~/.pub-cache"),
          os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pub", "Cache")]
rel = os.path.join("android", "src", "main", "java", "com", "cloudwebrtc", "webrtc", "MethodCallHandlerImpl.java")
src = next((p for p in (os.path.join(c, "hosted", "pub.dev", f"flutter_webrtc-{ver}", rel) for c in caches if c)
            if os.path.isfile(p)), None)
if src is None:
    sys.exit(f"MethodCallHandlerImpl.java of flutter_webrtc {ver} not found")
t = open(src, encoding="utf-8").read()
if ".setUseStereoInput(false)" in t and ".setUseStereoInput(true)" not in t:
    print(f"flutter_webrtc {ver}: mic already mono")
    sys.exit(0)
n = t.count(".setUseStereoInput(true)")
if n != 1:
    sys.exit(f"flutter_webrtc {ver}: expected one setUseStereoInput(true), found {n} — check the plugin")
open(src, "w", encoding="utf-8").write(t.replace(".setUseStereoInput(true)", ".setUseStereoInput(false)"))
print(f"flutter_webrtc {ver}: mic opened in mono ({src})")
