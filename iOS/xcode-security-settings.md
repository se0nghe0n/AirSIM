# Xcode Security Settings

Security build settings decisions for AirSIM (iOS/AirSIM.xcodeproj).

Maintained per the `audit-xcode-security-settings` skill. First recorded 2026-10-18,
after raising the iOS deployment target to 17.0 (watchOS stays 10.0). The approved
plan is kept at `iOS/xcode-security-audit-plan.md`. The Xcode-tools MCP server was
not bound to this worktree, so evaluated settings were read with
`xcodebuild -showBuildSettings` plus direct `project.pbxproj` inspection; the
project uses no `.xcconfig` files.

## Enabled settings

- `ENABLE_ENHANCED_SECURITY` to `YES` — project level (`PBXProject` Debug and Release
  configurations), so every current and future target inherits the Enhanced Security
  capability and its cascade (pointer authentication, stack zero-init, security
  compiler warnings, typed-allocator support, hardened libc++).
- `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` to `YES` — target level on
  `AirSIMWatchApp` and `AirSIMLiveActivityExtension`. Adds the `arm64e.x1` slice
  (verified with `lipo -archs`: watch `arm64 arm64_32 arm64e arm64e.x1`, extension
  `arm64 arm64e arm64e.x1`). Run time enforcement additionally requires the
  entitlement below and capable hardware (iOS A20 Pro+ / watchOS S11+).
- `ENABLE_POINTER_AUTHENTICATION` — `YES` via the project-level cascade on
  `AirSIMWatchApp` and `AirSIMLiveActivityExtension` (no explicit setting needed).
- Entitlements, added to `AirSIM/AirSIM.entitlements`,
  `AirSIMWatchApp/AirSIMWatchApp.entitlements`, and the new
  `AirSIMLiveActivityExtension/AirSIMLiveActivityExtension.entitlements` (wired via
  `CODE_SIGN_ENTITLEMENTS` in both configurations, same build-setting-only pattern the
  watch app already uses; no `.entitlements` file existed for the extension before):
  - `com.apple.security.hardened-process` = true (required main toggle)
  - `com.apple.security.hardened-process.enhanced-security-version-string` = "2"
  - `com.apple.security.hardened-process.hardened-heap` = true (default-ON; with the
    cascaded typed-allocator build settings)
  - `com.apple.security.hardened-process.dyld-ro` = true (default-ON)
  - `com.apple.security.hardened-process.platform-restrictions-string` = "2"
    (default-ON; dylib + Mach-message restrictions)
  - `com.apple.security.hardened-process.checked-allocations` = true (hardware memory
    tagging; owner-approved beyond the skill's default-OFF reporting state)
  - `com.apple.security.hardened-process.checked-allocations.soft-mode` = true
    (non-fatal rollout; simulated crash reports instead of termination)
  - `com.apple.security.hardened-process.checked-allocations.enforce-checked-pointer-arithmetic-overflow`
    = true — Watch app and Live Activity extension only (checked pointer arithmetic
    enforcement; no soft mode exists for this protection, so latent pointer-arithmetic
    bugs terminate the app on capable hardware).
- Existing keys untouched: `aps-environment` = `$(APS_ENVIRONMENT)` in the app and
  watch entitlements. No app-group entitlements exist anywhere in the project, and
  VoIP is a `UIBackgroundModes` value in the app and watch `Info.plist` files (not an
  entitlement), so no push or VoIP entitlement keys changed.

## Disabled settings

- `ENABLE_POINTER_AUTHENTICATION` = `NO` on the `AirSIM` app target (both
  configurations, target-level): the prebuilt WebRTC dependency
  (`WebRTCDependency`, `webrtc-sdk/Specs` 144.7559.15 XCFramework) ships `arm64`
  slices only — verified with `lipo -archs` on the downloaded
  `ios-arm64/WebRTC.framework/WebRTC` (no `arm64e`) — so the app cannot link an
  `arm64e` slice. Re-enable if the vendor ever ships an `arm64e` slice.
- `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` = `NO` on the `AirSIM` app target
  (both configurations, target-level): paired with the pointer-authentication opt-out
  per the skill (`arm64e.x1` is a pointer-authentication slice and must not be built
  where pointer authentication is off; a slice-less enforcement entitlement would
  only produce build warnings).
- `ENABLE_POINTER_AUTHENTICATION` = `NO` on the `AirSIMTests` target (both
  configurations, target-level): the test bundle is hosted by the `AirSIM` app
  (`BUNDLE_LOADER`/`TEST_HOST`) and imports the app module and the WebRTC framework
  directly; both are arm64-only on device, so an `arm64e` test slice has no app
  module or host binary to link against (reproduced: unsigned device
  `build-for-testing` failed with `SwiftDriver AirSIMTests normal arm64e` before this
  opt-out, and passed after it).
- `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` = `NO` on the `AirSIMTests`
  target (both configurations, target-level): paired with the pointer-authentication
  opt-out, same as the `AirSIM` app target.
- `treat-warnings-as-errors` — deliberately not enabled anywhere (owner rule).

## Deferred

Settings considered but not yet enabled. Revisit them later.

- Compiler warnings (`GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`,
  `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`,
  `CLANG_WARN_IMPLICIT_FALLTHROUGH` to `YES`, `GCC_WARN_64_TO_32_BIT_CONVERSION` to
  `YES`, `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS` to `YES`), static
  analyzer checkers (`CLANG_ANALYZER_SECURITY_FLOATLOOPCOUNTER`,
  `CLANG_ANALYZER_SECURITY_INSECUREAPI_RAND`,
  `CLANG_ANALYZER_SECURITY_INSECUREAPI_STRCPY`), and clang-tidy
  (`CLANG_TIDY_BUGPRONE_REDUNDANT_BRANCH_CONDITION`): the project is pure Swift
  (42 Swift sources; no C/C++/Objective-C files and no `sourcecode.cpp.*` type
  overrides), so these clang-scoped settings have no applicable code. Re-run the
  skill if C-family sources are added.
- Additional diagnostic settings (`CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`,
  `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL`, `CLANG_WARN_ASSIGN_ENUM`,
  `GCC_WARN_SIGN_COMPARE`, plus the ObjC/Blocks-scoped ones): left off by the
  approved plan; can be noisier. Mostly clang-scoped anyway.
- C bounds safety (`ENABLE_C_BOUNDS_SAFETY`) and C++ bounds-safe buffers
  (`ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS`): not applicable — no C/C++ sources.
  The hardened-libc++ portion of C++ hardening is already active via the
  `ENABLE_ENHANCED_SECURITY` cascade.
- Disabling `checked-allocations.soft-mode` (moving memory tagging from simulated
  crash reports to enforcement): deferred until simulated crash reports are reviewed
  on MTE-capable hardware (iPhone/iPad A19+, Apple Watch S11+).
- `AirSIMTests` stays without entitlements (test bundles are outside the skill's
  entitlement scope); it inherits the project-level Enhanced Security cascade except
  for the pointer-authentication opt-outs recorded under Disabled settings.

## Notes

- Simulator builds need no overrides: simulator SDKs define no `arm64e`/`arm64e.x1`
  architectures, so the build system drops those slices automatically.
- `xcodebuild -showBuildSettings` does not surface every default (e.g. the cascaded
  `CLANG_ENABLE_STACK_ZERO_INIT`, typed-allocator support, and hardened libc++
  settings are not listed); `ENABLE_SECURITY_COMPILER_WARNINGS = YES` in the evaluated
  output confirms the cascade is active.
- Validation: `build-for-testing` (generic iOS Simulator) and `build`
  (generic iOS device, `CODE_SIGNING_ALLOWED=NO`) both succeeded after the change;
  deduplicated compiler warnings unchanged (4 unique messages before and after).
  Reviewer round 1 (same day): the device failure was reproduced and fixed by the
  `AirSIMTests` opt-outs above; unsigned device `build-for-testing` now passes too,
  and simulator deduplicated warnings are unchanged across the fix (13 unique
  `file:line` warning lines before and after).
- `AirSIMLiveActivityExtension` hardening is an owner-approved override outside the
  skill's supported product types: `enhanced-security.md` lists applications, XPC
  services, driver/system extensions, and tools, and says to skip other app
  extensions, but the owner directed full inclusion (plan: "owner directed
  inclusion"). Every check so far ran with `CODE_SIGNING_ALLOWED=NO`, so Automatic
  granting of these entitlements to the extension's App ID is unverified until a
  signed device build or archive runs. CPA enforcement has no soft mode: a latent
  pointer-arithmetic bug would terminate the Live Activity process on capable
  hardware (iOS A20 Pro+).
- watchOS platform reading: `enhanced-security.md` says Enhanced Security applies on
  iOS, macOS, visionOS, and DriverKit, while `checked-pointer-arithmetic.md` and
  `hardware-memory-tagging.md` explicitly support watchOS S11; the skill references
  contradict each other. The reading followed here keeps the Watch app fully
  configured (hardened-process, memory tagging in soft mode, CPA), because the two
  protection-specific references cover watchOS directly. Signed-device confirmation
  is tracked in the "Not yet verified" list below.
- Not yet verified (do not present simulator results as device-ready): signed device
  `build-for-testing`; signed device install of the app, Watch app, and Live Activity
  extension (confirming Automatic signing grants the new entitlements to each App
  ID); archive and TestFlight processing; and a real-device
  CallKit/PushKit/WebRTC-audio/Live Activity smoke test with MTE soft-mode
  crash-report review.

## Validation commands

- `xcodebuild -project AirSIM.xcodeproj -scheme AirSIM -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/airsim-dd-security CODE_SIGNING_ALLOWED=NO build-for-testing` — passed.
- `xcodebuild -project AirSIM.xcodeproj -scheme AirSIM -destination 'generic/platform=iOS' -derivedDataPath /tmp/airsim-dd-security-dev CODE_SIGNING_ALLOWED=NO build` — passed.
- `xcodebuild -project AirSIM.xcodeproj -scheme AirSIM -destination 'generic/platform=iOS' -derivedDataPath /tmp/airsim-dd-security-dev CODE_SIGNING_ALLOWED=NO build-for-testing` — failed before the `AirSIMTests` opt-out (`SwiftDriver AirSIMTests normal arm64e`); passed after it.
- `lipo -archs` on the built app, watch app, and Live Activity extension binaries — slices as listed above.
