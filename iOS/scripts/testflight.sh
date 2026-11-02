#!/usr/bin/env bash
# Reserve the next shared version, archive the Release build and upload it to App Store Connect
# for TestFlight. Signing uses the Apple ID signed in to Xcode, or an App Store Connect API key
# when ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID are set.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: iOS/scripts/testflight.sh [--skip-bump] [--remote <name>]

  --skip-bump   Upload the version already in iOS/Config/Version.xcconfig again. Its
                ios/v<version>-<build> tag must point at HEAD (for example after a failed upload).
  --remote      Git remote holding the shared version tags (default: origin).
EOF
}

skip_bump=0
remote=origin
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-bump) skip_bump=1 ;;
    --remote) remote="${2:?--remote needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root"

if [[ $skip_bump -eq 0 ]]; then
  python3 iOS/scripts/version.py bump --remote "$remote"
fi
release="$(python3 iOS/scripts/version.py show)"
read -r version build <<<"$release"
tag="ios/v$version-$build"

# Upload only source that matches a pushed reservation, so a build number is never reused.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "testflight.sh: commit or stash tracked changes first" >&2
  exit 1
fi
git fetch --quiet --tags "$remote"
if [[ "$(git rev-parse -q --verify "refs/tags/$tag^{commit}" || true)" != "$(git rev-parse HEAD)" ]]; then
  echo "testflight.sh: $tag does not point at HEAD; run without --skip-bump" >&2
  exit 1
fi

auth=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "${ASC_KEY_ID:?ASC_KEY_ID is required with ASC_KEY_PATH}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required with ASC_KEY_PATH}")
fi

output="iOS/build/testflight/$version-$build"
archive="$output/AirSIM.xcarchive"
rm -rf "$output"
mkdir -p "$output"

# Package.resolved pins the TCA macro packages; skip Xcode's interactive per-Mac trust prompt.
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -skipMacroValidation \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} archive

properties="$archive/Info.plist"
archived_version="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$properties")"
archived_build="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$properties")"
team="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' "$properties")"
if [[ "$archived_version" != "$version" || "$archived_build" != "$build" ]]; then
  echo "testflight.sh: archive is $archived_version ($archived_build), expected $version ($build)" >&2
  exit 1
fi

# Xcode must not renumber the build: the shared tag already owns this number.
cat > "$output/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$team</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$output/ExportOptions.plist" \
  -exportPath "$output/export" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}

echo "Uploaded AirSIM $version ($build) from $tag. App Store Connect processes it before TestFlight shows it."
