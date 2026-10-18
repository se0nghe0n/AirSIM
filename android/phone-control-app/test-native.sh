#!/bin/bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDK=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
SERIAL=${AIRSIM_TEST_SERIAL:?set AIRSIM_TEST_SERIAL to the dedicated emulator serial}
case "$SERIAL" in emulator-*) ;; *) echo 'Native tests require an emulator, never a physical phone' >&2; exit 1;; esac
OUT="$ROOT/build/native-test"
APP="$ROOT/../../android-standalone/build/android/AirSIM-Android-Standalone-debug.apk"
TOOLS="$SDK/build-tools/35.0.0"
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"
"$JAVA_HOME/bin/javac" --release 17 -cp "$SDK/platforms/android-35/android.jar:$ROOT/build/dependencies/webrtc.jar:$ROOT/../../android-standalone/build/android/classes" -d "$OUT/classes" "$ROOT/test-native/com/airsim/phonecontrol/WebRTCNativeTests.java"
"$TOOLS/d8" --lib "$SDK/platforms/android-35/android.jar" --classpath "$ROOT/build/dependencies/webrtc.jar" --min-api 29 --output "$OUT/dex" "$OUT"/classes/com/airsim/phonecontrol/*.class
"$TOOLS/aapt2" link -I "$SDK/platforms/android-35/android.jar" --manifest "$ROOT/test-native/AndroidManifest.xml" -o "$OUT/test-unsigned.apk"
(cd "$OUT/dex" && zip -q -j "$OUT/test-unsigned.apk" classes*.dex)
"$TOOLS/zipalign" -f 4 "$OUT/test-unsigned.apk" "$OUT/test-aligned.apk"
"$TOOLS/apksigner" sign --ks "$ROOT/build/debug.keystore" --ks-pass pass:android --key-pass pass:android --out "$OUT/test.apk" "$OUT/test-aligned.apk"
"$SDK/platform-tools/adb" -s "$SERIAL" install --no-incremental -r "$APP"
"$SDK/platform-tools/adb" -s "$SERIAL" install --no-incremental -r "$OUT/test.apk"
trap '"$SDK/platform-tools/adb" -s "$SERIAL" shell run-as com.airsim.phonecontrol.pixel8pro rm -f files/webrtc-test-ice.json >/dev/null 2>&1 || true' EXIT
ARGS=(-e relay false)
if [ -n "${AIRSIM_TEST_TURN_CONFIG:-}" ]; then
    "$SDK/platform-tools/adb" -s "$SERIAL" shell run-as com.airsim.phonecontrol.pixel8pro mkdir -p files
    "$SDK/platform-tools/adb" -s "$SERIAL" shell 'run-as com.airsim.phonecontrol.pixel8pro sh -c "umask 077; cat > files/webrtc-test-ice.json"' < "$AIRSIM_TEST_TURN_CONFIG"
    ARGS=(-e relay true)
fi
python3 - "$SDK/platform-tools/adb" "$SERIAL" "${ARGS[@]}" <<'NATIVE_TEST' | tee "$OUT/result.txt"
import subprocess
import sys
adb, serial, *arguments = sys.argv[1:]
try:
    subprocess.run([adb, '-s', serial, 'shell', 'am', 'instrument', '-w', *arguments,
                    'com.airsim.webrtctest/com.airsim.phonecontrol.WebRTCNativeTests'],
                   timeout=90, check=True)
except subprocess.TimeoutExpired:
    subprocess.run([adb, '-s', serial, 'shell', 'am', 'force-stop',
                    'com.airsim.phonecontrol.pixel8pro'], timeout=10, check=False)
    raise SystemExit('FAIL: native loopback timed out')
NATIVE_TEST
grep -q 'PASS native JNI bidirectional Opus' "$OUT/result.txt"
