# Xcode Security Audit — Plan
**Project:** AirSIM · 4 targets · languages: Swift
**Generated:** 2026-10-18

Audit performed with the `audit-xcode-security-settings` skill. The Xcode-tools MCP server is not
bound to this worktree, so build settings were read via `xcodebuild -showBuildSettings -json` plus
direct `project.pbxproj` inspection, and settings are applied directly in `project.pbxproj`
(this project uses no `.xcconfig` files). This plan was pre-approved by the owner (Run on the
recommended plan); it is kept in the repository as the approval record.

## Scope detected

- 42 Swift sources; no C, C++, Objective-C, or Objective-C++ files and no `sourcecode.cpp.*`
  type overrides in `project.pbxproj`. The project is **pure Swift**, so the clang-based
  compiler-warning, static-analyzer, and clang-tidy settings tracked by the skill have no
  language scope here and the skill's plan omits the Warnings group entirely.
- Only the `AirSIM` app target links the prebuilt WebRTC binary XCFramework
  (`WebRTCDependency`, `webrtc-sdk/Specs` 144.7559.15). Its downloaded artifact contains
  `arm64` slices only (no `arm64e`).
- Nothing is explicitly disabled today: no tracked security setting appears in any
  `.xcconfig` (none exist) or in `project.pbxproj`, and no `xcode-security-settings.md`
  decision document existed before this run.

## Targets

| Target | Product type | Category |
|---|---|---|
| AirSIM | `com.apple.product-type.application` | Entitlements-supported / Off |
| AirSIMWatchApp | `com.apple.product-type.application` (watchOS) | Entitlements-supported / Off |
| AirSIMLiveActivityExtension | `com.apple.product-type.app-extension` | No-entitlements-file (owner directed inclusion) |
| AirSIMTests | `com.apple.product-type.bundle.unit-test` | Skipped (test bundle: inherits project settings, no entitlements) |

## Phases

- **Enhanced Security** — the project's runtime-protection bundle. Apply to: AirSIM,
  AirSIMWatchApp, AirSIMLiveActivityExtension. AirSIMTests inherits the project-level setting
  only (the skill excludes test bundles from entitlement work).
  - [x] **[Enable Enhanced Security](doc://com.apple.documentation/documentation/Xcode/enabling-enhanced-security-for-your-app)** — sets `ENABLE_ENHANCED_SECURITY=YES` at the project level in `project.pbxproj` (both Debug and Release), so every current and future target inherits it.
  - [x] **[Update entitlements](doc://com.apple.documentation/documentation/BundleResources/Entitlements/com.apple.security.hardened-process)** — adds the hardened-process entitlement family per target (required keys, plus default-ON hardened-heap / dyld-ro / platform-restrictions-string). Existing push, VoIP, and app-group keys are untouched. The Live Activity extension gets a new entitlements file wired via `CODE_SIGN_ENTITLEMENTS` (same build-setting-only pattern the watch app already uses).
  - [x] **[Hardware memory tagging](doc://com.apple.documentation/documentation/BundleResources/Entitlements/com.apple.security.hardened-process.checked-allocations)** — adds the hardware memory tagging entitlement in **soft mode** to AirSIM, AirSIMWatchApp, and AirSIMLiveActivityExtension (platforms `iphoneos` / `watchos` qualify). Run time enforcement needs iPhone/iPad A19+, Apple Watch S11+ hardware.
  - [x] **[Checked pointer arithmetic](doc://com.apple.documentation/documentation/BundleResources/Entitlements/com.apple.security.hardened-process.checked-allocations.enforce-checked-pointer-arithmetic-overflow)** — adds the `arm64e.x1` slice (`ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE=YES`) and the enforcement entitlement to AirSIMWatchApp and AirSIMLiveActivityExtension. **AirSIM is excluded**: it links the arm64-only WebRTC XCFramework, so per the skill it gets a target-level `ENABLE_POINTER_AUTHENTICATION=NO` with the paired `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE=NO`. Run time enforcement requires hardware memory tagging enabled and capable hardware (iOS A20 Pro+ / watchOS S11+); a latent pointer-arithmetic bug terminates the app on capable hardware.
- Warnings — omitted: the project is pure Swift, so the compiler-warning, static-analyzer, and
  clang-tidy settings (all clang-scoped) are not applicable.
- Inquire about disabled settings — omitted: no tracked setting is explicitly set to a
  non-hardened value anywhere in the project.

### Pointer authentication note (WebRTC)

Only pointer authentication cascades to `arm64e`. The prebuilt WebRTC XCFramework ships no
`arm64e` slice, so the correct mitigation is the target-level `ENABLE_POINTER_AUTHENTICATION=NO`
override on `AirSIM` — not skipping Enhanced Security. Watch and Live Activity targets link no
binary dependency and build `arm64` + `arm64e` (watch also keeps `arm64_32`); simulator builds
drop the arm64e/arm64e.x1 slices automatically, so no simulator-specific override is needed.
Revisit the override if the WebRTC SDK ever ships an `arm64e` slice.

### Deferred / not applied

- **Additional diagnostic settings** (`CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`,
  `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL`, `CLANG_WARN_ASSIGN_ENUM`,
  `GCC_WARN_SIGN_COMPARE`, ObjC/Blocks-specific ones) — left off per the recommended plan;
  none have language scope in a pure-Swift project anyway.
- **Compiler warnings / static analyzer / clang-tidy settings** — not applicable (pure Swift).
  If C/C++/Objective-C sources are ever added, re-run the skill to enable them.
- **C / C++ bounds safety** — not applicable (no C/C++ sources).
- `treat-warnings-as-errors` — deliberately not enabled (owner rule).

## Decision document

The skill creates `xcode-security-settings.md` to record every setting decision (kept,
deferred, disabled, with rationale).

- Path: `iOS/xcode-security-settings.md`
