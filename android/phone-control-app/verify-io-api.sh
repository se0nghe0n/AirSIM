#!/bin/sh
# Check known API 29 incompatibilities in emitted method references, not source spelling.
# This is a targeted regression gate, not a complete Android API lint replacement.
# java.util.List sequenced methods (removeFirst/removeLast/getFirst/getLast/
# reversed/addFirst/addLast) are included. Only classes we compiled are scanned,
# plus kotlin-stdlib classes those class files actually reference.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CLASSES=${1:-"$ROOT/build/android/classes"}
STDLIB=${2:-"$ROOT/build/dependencies/kotlin-stdlib-2.0.21.jar"}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home}
# Existing pre-33 alternatives are unchanged. List sequenced methods are appended.
banned_re='java/io/[^ ]+\.(toString:\(Ljava/nio/charset/Charset;|readNBytes:|writeBytes:\(\[B\)|nullInputStream:)|java/util/[^ ]+\.toArray:\(Ljava/util/function/IntFunction;|java/lang/(CharSequence|StringBuilder|StringBuffer)\.isEmpty:|java/net/(URLEncoder|URLDecoder)\.(encode|decode):\(Ljava/lang/String;Ljava/nio/charset/Charset;|java/util/List\.(removeFirst|removeLast|getFirst|getLast|reversed|addFirst|addLast):'
REPORT=$(mktemp "${TMPDIR:-/tmp}/airsim-io-api.XXXXXX")
POOL=$(mktemp "${TMPDIR:-/tmp}/airsim-io-pool.XXXXXX")
REFS=$(mktemp "${TMPDIR:-/tmp}/airsim-stdlib-refs.XXXXXX")
JAR_INDEX=$(mktemp "${TMPDIR:-/tmp}/airsim-stdlib-index.XXXXXX")
MATCHED=$(mktemp "${TMPDIR:-/tmp}/airsim-stdlib-matched.XXXXXX")
STDLIB_REPORT=$(mktemp "${TMPDIR:-/tmp}/airsim-stdlib-api.XXXXXX")
PART=$(mktemp "${TMPDIR:-/tmp}/airsim-stdlib-part.XXXXXX")
SCAN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/airsim-stdlib-classes.XXXXXX")
trap 'rm -f "$REPORT" "$POOL" "$REFS" "$JAR_INDEX" "$MATCHED" "$STDLIB_REPORT" "$PART"; rm -rf "$SCAN_DIR"' EXIT HUP INT TERM
find "$CLASSES" -name '*.class' -print0 | xargs -0 "$JAVA_HOME/bin/javap" -c -p > "$REPORT"
if grep -E "$banned_re" "$REPORT"; then
    echo 'FAIL: emitted Java calls require newer Android APIs, but AirSIM supports API 29+' >&2
    exit 1
fi
find "$CLASSES" -name '*.class' -print0 | xargs -0 "$JAVA_HOME/bin/javap" -v -p > "$POOL"
if [ ! -f "$STDLIB" ]; then
    if grep -q 'kotlin/' "$REPORT"; then
        echo "FAIL: compiled classes reference kotlin but stdlib jar is missing: $STDLIB" >&2
        exit 1
    fi
    echo 'Android pre-33 Java API regression check passed'
    exit 0
fi
# Descriptors are Lbinary/name; and a leading L would hide the real class name.
# Class and method comments use the binary name without that prefix.
: > "$REFS"
if grep -oE 'L[A-Za-z_$][A-Za-z0-9_$]*(/[A-Za-z0-9_$]+)+;' "$POOL" > "$PART"; then
    sed 's/^L//;s/;$//' "$PART" >> "$REFS"
fi
if grep -oE '// [A-Za-z_$][A-Za-z0-9_$]*(/[A-Za-z0-9_$]+)+' "$POOL" > "$PART"; then
    sed 's|^// ||' "$PART" >> "$REFS"
fi
if grep -oE '// (Method|InterfaceMethod|Field) [A-Za-z_$][A-Za-z0-9_$]*(/[A-Za-z0-9_$]+)+' "$POOL" > "$PART"; then
    sed -E 's#^// (Method|InterfaceMethod|Field) ##' "$PART" >> "$REFS"
fi
sort -u "$REFS" -o "$REFS"
unzip -l "$STDLIB" | sed -n 's/.* \([^ ][^ ]*\.class\)$/\1/p' | grep -v '^META-INF/versions/' | sed 's/\.class$//' | sort -u > "$JAR_INDEX"
comm -12 "$REFS" "$JAR_INDEX" > "$MATCHED"
if [ -s "$MATCHED" ]; then
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        mkdir -p "$SCAN_DIR/$(dirname "$name")"
        unzip -p "$STDLIB" "$name.class" > "$SCAN_DIR/$name.class"
    done < "$MATCHED"
    find "$SCAN_DIR" -name '*.class' -print0 | xargs -0 "$JAVA_HOME/bin/javap" -c -p > "$STDLIB_REPORT"
    if grep -E "$banned_re" "$STDLIB_REPORT"; then
        echo 'FAIL: emitted Java calls require newer Android APIs, but AirSIM supports API 29+' >&2
        exit 1
    fi
fi
echo 'Android pre-33 Java API regression check passed'
