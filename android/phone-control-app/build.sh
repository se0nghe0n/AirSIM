#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST_SOURCE=${AIRSIM_ANDROID_MANIFEST:-"$ROOT/../../android-standalone/AndroidManifest.xml"}
OUTPUT_BASENAME=${AIRSIM_ANDROID_OUTPUT_BASENAME:-AirSIM-Android-Standalone}
SDK=${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}
BUILD_TOOLS="$SDK/build-tools/35.0.0"
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
# shellcheck disable=SC1091
. "$ROOT/kotlin-toolchain.sh"
OUT=${AIRSIM_ANDROID_OUTPUT_DIR:-"$ROOT/build/android"}
CLASSES="$OUT/classes"
DEX="$OUT/dex"
DEPS="$ROOT/build/dependencies"
SHIZUKU_VERSION=13.1.5
WEBRTC_VERSION=144.7559.15
BUILD_VARIANT=${AIRSIM_ANDROID_BUILD_VARIANT:-debug}

case "$BUILD_VARIANT" in
  debug|release) ;;
  *) echo "AIRSIM_ANDROID_BUILD_VARIANT must be debug or release" >&2; exit 1 ;;
esac

rm -rf "$OUT"
mkdir -p "$CLASSES" "$DEX" "$DEPS"
airsim_prepare_kotlin "$DEPS"

download_verified "https://repo1.maven.org/maven2/dev/rikka/shizuku/api/$SHIZUKU_VERSION/api-$SHIZUKU_VERSION.aar" \
  "$DEPS/shizuku-api.aar" 4def9bde498ef8626614c2fc5db9af4749c86f16f6c33e3f5658d35e70bab59b
download_verified "https://repo1.maven.org/maven2/dev/rikka/shizuku/aidl/$SHIZUKU_VERSION/aidl-$SHIZUKU_VERSION.aar" \
  "$DEPS/shizuku-aidl.aar" 33fe7191cdd69fcb66d649264f3b0c47acb2f3d6343afc05b98dbbff6f221963
download_verified "https://repo1.maven.org/maven2/dev/rikka/shizuku/shared/$SHIZUKU_VERSION/shared-$SHIZUKU_VERSION.aar" \
  "$DEPS/shizuku-shared.aar" 4659642c9339be0a26e9c65bb8648f7ad6d8f4a465f557993ccbc78802381635
download_verified "https://repo1.maven.org/maven2/dev/rikka/shizuku/provider/$SHIZUKU_VERSION/provider-$SHIZUKU_VERSION.aar" \
  "$DEPS/shizuku-provider.aar" b0f18cd9812464ec171c53cac93a819fe411718a3965c311f01eb4de265381b3
download_verified "https://dl.google.com/dl/android/maven2/androidx/annotation/annotation/1.3.0/annotation-1.3.0.jar" \
  "$DEPS/androidx-annotation.jar" 97dc45afefe3a1e421da42b8b6e9f90491477c45fc6178203e3a5e8a05ee8553

download_verified "https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android/$WEBRTC_VERSION/android-$WEBRTC_VERSION.aar" \
  "$DEPS/webrtc-$WEBRTC_VERSION.aar" fc7c8d027eb33860ccbb7847988f7f942d44a92d1f575348bba6c0250cde4071
# Keep the native JNI class name but substitute our external PCM output adapter.
python3 "$ROOT/prepare-webrtc.py" "$DEPS/webrtc-$WEBRTC_VERSION.aar" "$DEPS/webrtc.jar" "$OUT/native"

SHIZUKU_JARS=("$DEPS/webrtc.jar")
for artifact in api aidl shared provider; do
  jar_path="$DEPS/shizuku-$artifact.jar"
  unzip -p "$DEPS/shizuku-$artifact.aar" classes.jar > "$jar_path"
  SHIZUKU_JARS+=("$jar_path")
done
SHIZUKU_JARS+=("$DEPS/androidx-annotation.jar")
CLASSPATH="$ANDROID_JAR:$(IFS=:; echo "${SHIZUKU_JARS[*]}")"

SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$ROOT/src" \( -name '*.java' -o -name '*.kt' \) -print0)
airsim_compile_classes --mode app --dest "$CLASSES" --classpath "$CLASSPATH" -- "${SOURCES[@]}"

sh "$ROOT/verify-io-api.sh" "$CLASSES"

CLASSES_ARGS=()
while IFS= read -r -d '' class_file; do CLASSES_ARGS+=("$class_file"); done < <(find "$CLASSES" -name '*.class' -print0)
"$BUILD_TOOLS/d8" --lib "$ANDROID_JAR" --min-api 29 --output "$DEX" "${CLASSES_ARGS[@]}" "${SHIZUKU_JARS[@]}" "$AIRSIM_KOTLIN_STDLIB"
COMPILED_RES="$OUT/compiled-res.zip"
"$BUILD_TOOLS/aapt2" compile --dir "$ROOT/res" -o "$COMPILED_RES"
MANIFEST="$OUT/AndroidManifest.xml"
if [ "$BUILD_VARIANT" = release ]; then
  sed 's/android:debuggable="true"/android:debuggable="false"/' \
    "$MANIFEST_SOURCE" > "$MANIFEST"
else
  cp "$MANIFEST_SOURCE" "$MANIFEST"
fi
"$BUILD_TOOLS/aapt2" link -o "$OUT/unsigned.apk" -I "$ANDROID_JAR" \
  --manifest "$MANIFEST" "$COMPILED_RES"
(cd "$DEX" && zip -q -j "$OUT/unsigned.apk" classes*.dex)
mkdir -p "$OUT/native/assets/webrtc"
cp "$ROOT/third_party/webrtc/"* "$OUT/native/assets/webrtc/"
(cd "$OUT/native" && zip -q -0 -r "$OUT/unsigned.apk" lib assets)
"$BUILD_TOOLS/zipalign" -P 16 -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

if [ "$BUILD_VARIANT" = debug ]; then
  KEYSTORE="$ROOT/build/debug.keystore"
  if [ ! -f "$KEYSTORE" ]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android \
      -alias androiddebugkey -dname "CN=AirSIM Debug,O=AirSIM,C=CN" -keyalg RSA -keysize 2048 -validity 3650 >/dev/null 2>&1
  fi
  OUTPUT_APK="$OUT/$OUTPUT_BASENAME-debug.apk"
  "$BUILD_TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --out "$OUTPUT_APK" "$OUT/aligned.apk"
else
  : "${AIRSIM_ANDROID_KEYSTORE:?set AIRSIM_ANDROID_KEYSTORE for a release build}"
  : "${AIRSIM_ANDROID_KEY_ALIAS:?set AIRSIM_ANDROID_KEY_ALIAS for a release build}"
  : "${AIRSIM_ANDROID_KEYSTORE_PASSWORD:?set AIRSIM_ANDROID_KEYSTORE_PASSWORD for a release build}"
  : "${AIRSIM_ANDROID_KEY_PASSWORD:?set AIRSIM_ANDROID_KEY_PASSWORD for a release build}"
  if [ ! -f "$AIRSIM_ANDROID_KEYSTORE" ]; then
    echo "release keystore not found: $AIRSIM_ANDROID_KEYSTORE" >&2
    exit 1
  fi
  OUTPUT_APK="$OUT/$OUTPUT_BASENAME-release.apk"
  "$BUILD_TOOLS/apksigner" sign \
    --ks "$AIRSIM_ANDROID_KEYSTORE" \
    --ks-key-alias "$AIRSIM_ANDROID_KEY_ALIAS" \
    --ks-pass env:AIRSIM_ANDROID_KEYSTORE_PASSWORD \
    --key-pass env:AIRSIM_ANDROID_KEY_PASSWORD \
    --out "$OUTPUT_APK" "$OUT/aligned.apk"
fi
"$BUILD_TOOLS/apksigner" verify --verbose --print-certs "$OUTPUT_APK"
echo "$OUTPUT_APK"
