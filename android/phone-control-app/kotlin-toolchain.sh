# Shared Kotlin 2.4.21 pin and two-pass compilation for the shell build.
# Source this file from build.sh and test.sh. Checksums are sha256 of the
# downloaded artifacts (kotlin-compiler zip and kotlin-stdlib jar).

airsim_kotlin_version=2.4.21
airsim_kotlin_compiler_sha256=7cc140e76daf416a0424a5557f99afd7ca89ebd463ea1101261e3e01c33e75cd
airsim_kotlin_stdlib_sha256=bd8250210584cb659847dce9cda660f8e9906e5def7fbebcea93dc6dcb6a88a3

download_verified() {
  local url=$1
  local output=$2
  local expected=$3
  if [ ! -f "$output" ]; then curl -fsSL "$url" -o "$output"; fi
  local actual
  actual=$(shasum -a 256 "$output" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "dependency checksum mismatch: $output" >&2
    # Drop a partial or corrupt download so the next run fetches it again.
    rm -f "$output"
    exit 1
  fi
}

airsim_prepare_kotlin() {
  local deps=$1
  local version=$airsim_kotlin_version
  mkdir -p "$deps"
  download_verified \
    "https://github.com/JetBrains/kotlin/releases/download/v${version}/kotlin-compiler-${version}.zip" \
    "$deps/kotlin-compiler-${version}.zip" \
    "$airsim_kotlin_compiler_sha256"
  download_verified \
    "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/${version}/kotlin-stdlib-${version}.jar" \
    "$deps/kotlin-stdlib-${version}.jar" \
    "$airsim_kotlin_stdlib_sha256"
  AIRSIM_KOTLIN_STDLIB="$deps/kotlin-stdlib-${version}.jar"
  AIRSIM_KOTLINC="$deps/kotlinc-${version}/bin/kotlinc"
  if [ ! -x "$AIRSIM_KOTLINC" ]; then
    rm -rf "$deps/kotlinc-${version}" "$deps/kotlinc-extract-${version}"
    mkdir -p "$deps/kotlinc-extract-${version}"
    unzip -q "$deps/kotlin-compiler-${version}.zip" -d "$deps/kotlinc-extract-${version}"
    mv "$deps/kotlinc-extract-${version}/kotlinc" "$deps/kotlinc-${version}"
    rm -rf "$deps/kotlinc-extract-${version}"
    chmod +x "$AIRSIM_KOTLINC"
  fi
}

# airsim_compile_classes --mode test|app --dest DIR --classpath CP -- sources...
# test: javac --release 17. app: javac -source 17 -target 17 -Xlint:all.
# An all-Java batch stays on javac. A batch with any .kt file runs kotlinc on
# the .kt files, passing that batch's .java files only so names can be resolved
# (kotlinc does not emit .class for them), then javac on the .java files with
# the kotlinc output prepended to the batch classpath.
# Do not put android.jar overlay stubs in the same batch as the real classes.
# Those stubs are a later all-Java compile into the same output directory.
airsim_compile_classes() (
  set -eu
  dest=
  classpath=
  mode=
  while [ $# -gt 0 ]; do
    case $1 in
      --dest) dest=$2; shift 2 ;;
      --classpath) classpath=$2; shift 2 ;;
      --mode) mode=$2; shift 2 ;;
      --) shift; break ;;
      *) echo "airsim_compile_classes: unexpected argument: $1" >&2; exit 1 ;;
    esac
  done
  if [ -z "$dest" ] || [ -z "$mode" ]; then
    echo "airsim_compile_classes: --dest and --mode are required" >&2
    exit 1
  fi
  if [ $# -eq 0 ]; then
    echo "airsim_compile_classes: no sources" >&2
    exit 1
  fi
  case $mode in
    test|app) ;;
    *) echo "airsim_compile_classes: unknown mode: $mode" >&2; exit 1 ;;
  esac
  javac=${JAVA_HOME:?}/bin/javac
  kt_list=$(mktemp "${TMPDIR:-/tmp}/airsim-kt-sources.XXXXXX")
  java_list=$(mktemp "${TMPDIR:-/tmp}/airsim-java-sources.XXXXXX")
  trap 'rm -f "$kt_list" "$java_list"' EXIT HUP INT TERM
  for src in "$@"; do
    case $src in
      *.kt) printf '%s\n' "$src" >> "$kt_list" ;;
      *.java) printf '%s\n' "$src" >> "$java_list" ;;
      *) echo "airsim_compile_classes: unsupported source: $src" >&2; exit 1 ;;
    esac
  done
  if [ ! -s "$kt_list" ]; then
    set --
    while IFS= read -r line; do
      set -- "$@" "$line"
    done < "$java_list"
    if [ "$mode" = app ]; then
      if [ -n "$classpath" ]; then
        "$javac" -source 17 -target 17 -Xlint:all -classpath "$classpath" -d "$dest" "$@"
      else
        "$javac" -source 17 -target 17 -Xlint:all -d "$dest" "$@"
      fi
    else
      if [ -n "$classpath" ]; then
        "$javac" --release 17 -classpath "$classpath" -d "$dest" "$@"
      else
        "$javac" --release 17 -d "$dest" "$@"
      fi
    fi
    exit 0
  fi
  if [ -z "${AIRSIM_KOTLINC:-}" ] || [ ! -x "$AIRSIM_KOTLINC" ]; then
    echo "airsim_compile_classes: kotlin compiler is not prepared" >&2
    exit 1
  fi
  if [ -z "${AIRSIM_KOTLIN_STDLIB:-}" ] || [ ! -f "$AIRSIM_KOTLIN_STDLIB" ]; then
    echo "airsim_compile_classes: kotlin-stdlib is not prepared" >&2
    exit 1
  fi
  if [ -n "$classpath" ]; then
    kotlin_cp="$classpath:$AIRSIM_KOTLIN_STDLIB"
    javac_cp="$dest:$classpath:$AIRSIM_KOTLIN_STDLIB"
  else
    kotlin_cp="$AIRSIM_KOTLIN_STDLIB"
    javac_cp="$dest:$AIRSIM_KOTLIN_STDLIB"
  fi
  set --
  while IFS= read -r line; do
    set -- "$@" "$line"
  done < "$kt_list"
  if [ -s "$java_list" ]; then
    while IFS= read -r line; do
      set -- "$@" "$line"
    done < "$java_list"
  fi
  # -no-stdlib keeps resolution on the pinned kotlin-stdlib jar.
  # -Xjdk-release=17 also selects JVM target 17; -jvm-target 17 is passed explicitly.
  "$AIRSIM_KOTLINC" \
    -jvm-target 17 \
    -Xjdk-release=17 \
    -Xlambdas=class \
    -Xsam-conversions=class \
    -no-stdlib \
    -classpath "$kotlin_cp" \
    -d "$dest" \
    "$@"
  if [ ! -s "$java_list" ]; then
    exit 0
  fi
  set --
  while IFS= read -r line; do
    set -- "$@" "$line"
  done < "$java_list"
  if [ "$mode" = app ]; then
    "$javac" -source 17 -target 17 -Xlint:all -classpath "$javac_cp" -d "$dest" "$@"
  else
    "$javac" --release 17 -classpath "$javac_cp" -d "$dest" "$@"
  fi
)
