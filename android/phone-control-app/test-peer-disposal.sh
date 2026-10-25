#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/build/jvm-peer-disposal"
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
JAVAC="$JAVA_HOME/bin/javac"
JAVA="$JAVA_HOME/bin/java"
ANDROID_JAR="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}/platforms/android-35/android.jar"
WEBRTC_JAR="$ROOT/build/dependencies/webrtc.jar"
JSON_JAR="$ROOT/build/dependencies/json-test-20240303.jar"

# Offline by design: reuse the dependencies pinned by build.sh and test.sh.
for dependency in "$JAVAC" "$JAVA" "$ANDROID_JAR" "$WEBRTC_JAR" "$JSON_JAR"; do
  if [ ! -f "$dependency" ]; then
    echo "FAIL: peer disposal test dependency is missing: $dependency" >&2
    exit 1
  fi
done
if [ "$(shasum -a 256 "$JSON_JAR" | awk '{print $1}')" != 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed ]; then
  echo 'FAIL: test JSON dependency checksum mismatch' >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/production" "$OUT/test" "$OUT/no-native-libraries"
CLASSPATH="$JSON_JAR:$WEBRTC_JAR:$ANDROID_JAR"
SOURCE="$ROOT/src/com/airsim/phonecontrol"
TEST="$ROOT/test/peer-disposal/com/airsim/phonecontrol"

# Compile the actual peer and carrier implementation. Only Android logging is stubbed here.
"$JAVAC" --release 17 -sourcepath '' -cp "$CLASSPATH" -d "$OUT/production" \
  "$TEST/BridgeLog.java" \
  "$SOURCE/PrivilegedBridgeProtocol.java" \
  "$SOURCE/WebRTCPcmBuffer.java" \
  "$SOURCE/WebRTCPlayout.java" \
  "$SOURCE/WebRTCOpusSDP.java" \
  "$SOURCE/WebRTCReadiness.java" \
  "$SOURCE/WebRTCStatistics.java" \
  "$SOURCE/TelephonyAudioDevice.java" \
  "$SOURCE/TelephonyWebRTCPeer.java"

# Shadow only the carrier boundary at runtime; PeerConnection and all SDK types remain real.
"$JAVAC" --release 17 -sourcepath '' -cp "$OUT/production:$CLASSPATH" -d "$OUT/test" \
  "$TEST/TelephonyAudioDevice.java" \
  "$TEST/TelephonyWebRTCPeerDisposalTests.java"
"$JAVA" -Djava.library.path="$OUT/no-native-libraries" \
  -cp "$OUT/test:$OUT/production:$CLASSPATH" \
  com.airsim.phonecontrol.TelephonyWebRTCPeerDisposalTests
