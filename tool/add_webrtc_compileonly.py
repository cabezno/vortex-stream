"""Add compileOnly(io.github.webrtc-sdk:android:<v>) to the app's build.gradle, with <v> = the WebRTC SDK version that
the resolved flutter_webrtc bundles (pubspec.lock + that package's android/build.gradle). Run from the Flutter project
root after `flutter pub get`. The Switcher mode's native code (StudioSwitcherPlugin) compiles against those classes."""
import glob, os, re, sys

lock = open("pubspec.lock", encoding="utf-8").read()
m = re.search(r"\n  flutter_webrtc:\n(?:    .*\n)*?    version: \"([^\"]+)\"", lock)
if not m:
    sys.exit("flutter_webrtc not in pubspec.lock")
ver = m.group(1)
# Pub cache: $PUB_CACHE, else ~/.pub-cache (Linux/macOS, CI), else %LOCALAPPDATA%\Pub\Cache (Windows).
caches = [os.environ.get("PUB_CACHE"), os.path.expanduser("~/.pub-cache"),
          os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pub", "Cache")]
gradle = next(g for g in (os.path.join(c, "hosted", "pub.dev", f"flutter_webrtc-{ver}", "android", "build.gradle")
                          for c in caches if c) if os.path.isfile(g))
sdk = re.search(r"io\.github\.webrtc-sdk:android:([0-9.]+)", open(gradle, encoding="utf-8").read()).group(1)
for f in glob.glob("android/app/build.gradle*"):
    t = open(f, encoding="utf-8").read()
    if "webrtc-sdk" not in t:
        t += f'\ndependencies {{\n    compileOnly("io.github.webrtc-sdk:android:{sdk}")\n}}\n'
        open(f, "w", encoding="utf-8").write(t)
print(f"flutter_webrtc {ver} -> compileOnly webrtc-sdk {sdk}")
