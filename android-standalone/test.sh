#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST="$ROOT/AndroidManifest.xml"

assert_contains() {
  if ! grep -Fq "$2" "$1"; then
    echo "FAIL: $3" >&2
    exit 1
  fi
}

assert_not_contains() {
  if grep -Fq "$2" "$1"; then
    echo "FAIL: $3" >&2
    exit 1
  fi
}

assert_contains "$MANIFEST" 'com.airsim.phonecontrol.StandaloneAgentService' \
  'embedded Agent foreground service is missing'
assert_contains "$MANIFEST" 'android.permission.RECEIVE_SMS' \
  'standalone cannot receive carrier SMS'
assert_contains "$MANIFEST" 'android.permission.READ_SMS' \
  'standalone cannot use the optional inbox fallback'
assert_contains "$MANIFEST" 'com.airsim.phonecontrol.IncomingSMSReceiver' \
  'standalone carrier SMS receiver is missing'
assert_not_contains "$MANIFEST" 'com.android.virtualization.terminal' \
  'standalone APK must not query or depend on Linux Terminal'
assert_not_contains "$MANIFEST" 'AgentWatchdogService' \
  'standalone APK must not declare the AVF watchdog'

"$ROOT/../android/phone-control-app/test.sh"

"$ROOT/build.sh" >/dev/null
"$ROOT/../android/phone-control-app/test-peer-disposal.sh"
APK="$ROOT/build/android/AirSIM-Android-Standalone-debug.apk"
APKANALYZER=${APKANALYZER:-$(command -v apkanalyzer || true)}
if [ -z "$APKANALYZER" ]; then
  echo "FAIL: apkanalyzer is required to verify the built role manifest" >&2
  exit 1
fi
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home} \
  "$APKANALYZER" manifest print "$APK" | python3 "$ROOT/test/verify_dialer_manifest.py" "$MANIFEST"
echo "Standalone Bridge tests passed"
