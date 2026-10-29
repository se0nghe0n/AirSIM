#!/bin/sh
# Check known API 29 incompatibilities in emitted method references, not source spelling.
# This is a targeted regression gate, not a complete Android API lint replacement.
# The constant pool is scanned so method handles (List::removeFirst) are caught too.
# ponytail: only classes we compile are scanned; the pinned kotlin-stdlib is trusted
# as Android-compatible. Scan it too if a stdlib upgrade ever ships a pre-29 call.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLASSES=${1:-"$ROOT/build/android/classes"}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
REPORT=$(mktemp "${TMPDIR:-/tmp}/airsim-io-api.XXXXXX")
trap 'rm -f "$REPORT"' EXIT HUP INT TERM
find "$CLASSES" -name '*.class' -print0 | xargs -0 "$JAVA_HOME/bin/javap" -v -p > "$REPORT"
if grep -E 'java/io/[^ ]+\.(toString:\(Ljava/nio/charset/Charset;|readNBytes:|writeBytes:\(\[B\)|nullInputStream:)|java/util/[^ ]+\.toArray:\(Ljava/util/function/IntFunction;|java/lang/(CharSequence|StringBuilder|StringBuffer)\.isEmpty:|java/net/(URLEncoder|URLDecoder)\.(encode|decode):\(Ljava/lang/String;Ljava/nio/charset/Charset;|java/util/(List|ArrayList)\.(removeFirst|removeLast|getFirst|getLast|reversed|addFirst|addLast):' "$REPORT"; then
    echo 'FAIL: emitted Java calls require newer Android APIs, but AirSIM supports API 29+' >&2
    exit 1
fi
echo 'Android API 29 Java API regression check passed'
