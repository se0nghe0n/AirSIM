#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
AAPT2=${AAPT2:-$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt2}
APK=${1:-$ROOT/build/android/AirSIM-Android-Standalone-debug.apk}

permissions=$($AAPT2 dump permissions "$APK")
manifest=$($AAPT2 dump xmltree --file AndroidManifest.xml "$APK")

case "$permissions" in
  *moe.shizuku.manager.permission.API_V23*) ;;
  *) echo "FAIL: Shizuku API permission missing from APK" >&2; exit 1 ;;
esac
case "$manifest" in
  *moe.shizuku.client.V3_SUPPORT*) ;;
  *) echo "FAIL: Shizuku V3 client marker missing from APK" >&2; exit 1 ;;
esac
case "$manifest" in
  *com.airsim.phonecontrol.pixel8pro.shizuku*) ;;
  *) echo "FAIL: Shizuku provider authority missing from APK" >&2; exit 1 ;;
esac

case "$manifest" in
  *StandaloneBridgeApplication*StandaloneAgentService*) ;;
  *) echo "FAIL: Standalone application/service missing from APK" >&2; exit 1 ;;
esac
case "$manifest" in
  *AgentWatchdogService*|*com.android.virtualization.terminal*)
    echo "FAIL: retired Linux startup path remains in APK manifest" >&2; exit 1 ;;
esac

python3 - "$APK" <<'PY'
import sys, zipfile
retired = ("AgentWatchdogService", "AVFEnvironmentActions", "AVFEnvironmentDetector",
           "AVFStartupPolicy", "AVFNetworkPolicy", "InstallerClient", "AgentReleaseManager",
           "ReleaseAssetSelector", "RuntimeMode")
with zipfile.ZipFile(sys.argv[1]) as apk:
    dex = b"".join(apk.read(name) for name in apk.namelist() if name.endswith(".dex"))
    for name in retired:
        descriptor = ("Lcom/airsim/phonecontrol/" + name + ";").encode()
        if descriptor in dex:
            raise SystemExit("FAIL: retired runtime class remains in APK: " + name)
print("APK Standalone runtime verified; retired classes absent")
PY

echo "APK Shizuku integration verified"
