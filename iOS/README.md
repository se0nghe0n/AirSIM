# AirSIM iOS and watchOS

This directory contains the iPhone app, Apple Watch app, Live Activity, and shared models for a compatible Android phone endpoint. Clients can connect directly over VoWLAN, or use a separately deployed Cloudflare Relay for remote calls and SMS.

The documented app build is `0.9.7 (81)`, supplied as an unsigned IPA with [Apps v0.9.7.1](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1). The upstream maintainer separately uploads production builds through Xcode to TestFlight; upload, processing, and review must be checked separately. The maintainer's `com.eric3u.airsim` build uses `https://airsim-push.remotepilot.site`; changing the Bundle ID requires your own Relay and APNs credentials.

## Xcode project

Open:

```text
iOS/AirSIM.xcodeproj
```

Main targets:

- `AirSIM`: main iPhone / iPad app
- `AirSIMWatchApp`: Apple Watch App
- `AirSIMLiveActivityExtension`: Lock Screen and Dynamic Island Live Activities
- `AirSIMTests`: transport selection and protocol-boundary tests

## Client capabilities

- One-time encrypted pairing with an Android device; see the [verified hardware and compatibility scope](../README.md#android-compatibility-and-verification)
- VoWLAN discovery, HMAC authentication, and health checks
- CallKit dialing, incoming calls, answer, hang-up, mute, and DTMF
- PushKit, notification APNs, and ActivityKit
- Microphone permission is requested first on entering the foreground. Local discovery and notification authorization start only after the microphone permission decision. If the system defers the prompt, it retries on the next foreground entry without requiring re-pairing.
- Apple Watch companion dialing, answering, mute, and hang-up. Call audio uses the paired iPhone microphone, speaker, or headset; independent Watch voice is not supported.
- SMS list, sending, notifications, and contact integration
- VoWLAN and cloud Relay transport selection. Automatic mode selects only actually available dialing routes, with fixed priority VoWLAN, then cloud.
- Both cloud and local VoWLAN call audio use native WebRTC Opus. NetEq holds at most 50 packets (one second at 20 ms) and fast-accelerates when that buffer grows. Dormant PCM network engines, resampling, framing, and time-pitch helpers have been removed. See [WebRTC calls](../docs/webrtc.md). Old states are still prevented from reopening the call UI after hang-up.
- Settings show current VoWLAN/cloud mode and Agent heartbeat status.
- Cloud mode queries Relay status once on foreground entry and again when cloud dialing is needed. Dynamic Island waits for one status query before displaying a call, including background incoming calls. Local mode does not query Relay; VoWLAN loss and background standby updates do not start periodic cloud queries, avoiding repeated quota consumption.
- Four-stage cloud diagnostics: local push credentials, Relay identity, device registration, and Agent heartbeat
- Local call history, swipe-to-delete, deletion from details, diagnostics, and media health

When the current call is known, VoWLAN answer, reject, and hang-up requests include the `call_id` returned by `/api/calls/status` (JSON field `call_id`). Standalone validates it so an old notification cannot affect a subsequent call. Before a call ID is available, an empty request remains compatible with older Agents.

### SMS and push notifications

AirSIM and DJOneHub use the same division of responsibilities but separate Relays and APNs topics. For outgoing SMS, iPhone calls the Agent directly if VoWLAN is ready. If offline with cloud mode enabled, it submits a device-authenticated `send_sms` command to the Relay, and the Standalone Agent executes it and returns the result. Incoming SMS reaches the Relay as an Agent event with `delivery_id`; the Relay sends a normal APNs `alert` on the main app topic. The app saves local history and deduplicates against the next Agent sync using `delivery_id`. Opening a notification navigates to the sender's conversation, including after a cold start.

PushKit VoIP push is only for real incoming calls handled by CallKit; it must not carry SMS bodies or wake SMS-send tasks. SMS notifications require notification permission, an iPhone alert token, valid Relay/Agent registration, and a current heartbeat. iOS controls ordinary APNs delivery and background execution. Acceptance must separately test foreground, locked screen, cold start, and cloud sending; control-plane diagnostics alone do not establish successful SMS operation.

## Initial setup

1. Start AirSIM on Samsung and confirm the Agent and Shizuku audio bridge are ready.
2. Connect iPhone to the Samsung hotspot or the same LAN.
3. Open the two-minute pairing window on Samsung.
4. On iPhone, select the pairing method in “Pair Android Phone,” then enter the Android six-digit code. With “Local Mode Pairing” on, pairing writes only VoWLAN keys and does not read or write Relay/push parameters. With it off, pairing writes cloud configuration and reports missing credentials rather than silently falling back. Its initial value follows global local mode, but changing it affects only this pairing and does not change global settings; it cannot be changed during pairing. Pairing waits for in-flight Agent registration writes, and automatic registration recognizes Android's local pairing state. Other devices' global Relay-token refresh is not disabled.
5. Wait for VoWLAN to show Ready.
6. For remote mode, enter a separate Relay URL matching the app's signing identity under “Cloud Relay,” select “Save Relay URL,” and enable “Remote Calls and SMS.” The maintainer's `com.eric3u.airsim` build uses `https://airsim-push.remotepilot.site`; other Bundle IDs require a self-deployed Relay.
7. Open “Settings → Cloud Mode Diagnostics.” All four checks must pass for cloud control readiness. “Relay Identity” rejects DJOneHub and other services; “Agent Heartbeat” requires a report from the Standalone Agent within 90 seconds. Diagnostics do not dial or send SMS.

### Manage paired Android devices

Below “Settings → Samsung Connection → Pair Android Phone,” the paired-device list shows current device names, numbers, and VoWLAN/cloud status, with individual deletion confirmation. Offline history stores only device ID, name, and Agent type, not phone numbers. If a number cannot be read or is not provided by the SIM, it shows “Number not provided” without filling in a historical number.

Deletion removes the local list entry and manual binding for that device and retains a marker preventing automatic reconnection. Other devices, call history, and SMS are unaffected. Deleted devices must be explicitly paired again and cannot be restored by advertising or stale cloud status.

Reconnection uses current advertisements and authentication checks rather than a cached peripheral UUID. Newer Android APKs support authenticated BLE `device_info`; older APKs do not substitute historical VoWLAN/Relay numbers. Standalone cloud heartbeats and local health checks read the current calling SIM, not the number saved at initial pairing. Saved retired Agent records remain readable without becoming a supported runtime. Existing Apple pairing credentials, SMS history and recordings are preserved.

## Build and test

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Run tests on a named simulator:

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Signing and push

When re-signing a diagnostic package from a `CODE_SIGNING_ALLOWED=NO` Debug build, sign every embedded dynamic library first, including the main app's and Live Activity extension's `*.debug.dylib` and `__preview.dylib`. Then sign extensions and the main app from the inside out. Running only `codesign --verify --deep --strict` on `.app` does not prove the Debug libraries at the bundle root are signed. Verify each `.dylib` separately and confirm the process stays alive after device launch. Missing signatures cause a DYLD `Library missing / missing code signature` crash before app code runs.

This is a source-available, noncommercial project. It does not provide the original author's Apple Developer Team, App IDs, certificates, or provisioning profiles. Project `com.example.airsim` is a placeholder, not a releasable identity. Before the first device build, configure and sign using your own Apple Developer account:

1. Select your Team for `AirSIM` in Xcode and set a unique Bundle Identifier you control, such as `org.example.airsim`.
2. Set the Watch app to the main identifier plus `.watchkitapp`, such as `org.example.airsim.watchkitapp`, and set `WKCompanionAppBundleIdentifier` to the main app identifier.
3. Set the Live Activity Extension to the main identifier plus `.liveactivity`, such as `org.example.airsim.liveactivity`; the test target can use the main identifier plus `.tests`.
4. Create Explicit App IDs for all three production targets in Apple Developer, enable required capabilities, and regenerate development/distribution provisioning profiles for your Team.
5. Set Relay `ALLOWED_BUNDLE_ID` to the same main app identifier. PushKit, Watch, and Live Activity APNs topics derive from it.

Replacing only a certificate while retaining someone else's Bundle ID does not grant access to that App ID/APNs topic. Main app, Watch, Live Activity, provisioning profiles, and Relay must use consistent identifier relationships.

Inject the Relay URL through `AIRSIM_PUSH_RELAY_URL` and the APNs environment through `AIRSIM_APNS_ENVIRONMENT`. Debug development signing uses APNs `sandbox`; Release/TestFlight uses `production`.

Enhanced Security entitlements (see `xcode-security-settings.md`): when re-signing, keep the `com.apple.security.hardened-process` family present in each target's `.entitlements` file — `com.apple.security.hardened-process`, `com.apple.security.hardened-process.enhanced-security-version-string` (`2`), `com.apple.security.hardened-process.hardened-heap`, `com.apple.security.hardened-process.dyld-ro`, `com.apple.security.hardened-process.platform-restrictions-string` (`2`), `com.apple.security.hardened-process.checked-allocations`, and `com.apple.security.hardened-process.checked-allocations.soft-mode`; the Watch app and Live Activity extension additionally carry `com.apple.security.hardened-process.checked-allocations.enforce-checked-pointer-arithmetic-overflow`. The Live Activity extension now has its own `AirSIMLiveActivityExtension.entitlements`, so regenerate its App ID and provisioning profile together with the other targets. Removing these keys silently weakens runtime hardening and can produce signing/validation warnings.

Do not enter DJOneHub's `https://push.remotepilot.site` in AirSIM. It accepts only DJOneHub Bundle IDs. AirSIM and DJOneHub device registration, command queues, media sessions, and Dashboards are isolated. The maintainer's AirSIM URL accepts only `com.eric3u.airsim`; users changing Bundle ID must also change Relay `ALLOWED_BUNDLE_ID` and APNs credentials.

New installations require Samsung pairing, notification authorization, CallKit/PushKit registration, and Watch companion installation again.

The GitHub Release `AirSIM-iOS-<version>-unsigned.ipa` is a re-signing package whose main app binary is arm64 (the embedded Watch app and Live Activity extension binaries also carry `arm64e`/`arm64e.x1` slices), without `_CodeSignature` or `embedded.mobileprovision`; it cannot be installed directly. Signing only the main app is insufficient: replace and sign the Watch app and Live Activity Extension Bundle IDs, entitlements, and provisioning profiles as well. Public Releases must not contain development/ad hoc IPAs exposing device UDIDs.

## Security and privacy

- Store the VoWLAN secret in Keychain, never UserDefaults or logs.
- Pairing uses X25519, HKDF-SHA256, and AES-256-GCM.
- Control requests use HMAC-SHA256, time windows, and nonces for replay protection.
- Keep uncompressed call samples inside the native audio device and WebRTC processing callbacks unless the user explicitly starts an iPhone recording. Protect saved files, exclude them from backups, and never upload them or include audio in diagnostics.
- Logs and error screens must not expose device secrets, HMAC, push tokens, or complete media URLs.

## Current status

Simulator builds and tests cover the main protocol and transport-selection logic. A release still requires Apple signing, installation on physical iPhone/Apple Watch devices, Samsung dialing and answering, bidirectional voice, SMS, and background-push acceptance.

## Native WebRTC-only audio

The iPhone advertises and requests only `webrtc`. `legacy_pcm` is not an iPhone
cloud carrier, and `airsim.cloud-media-force-legacy-pcm` does not select PCM.
A failed WebRTC negotiation does not open a PCM engine. Binary frames on the
call WebSocket are ignored; SDP and call control stay on that socket.

The iPhone offers only after its WebSocket owner handshake is acknowledged and the
CallKit audio startup policy permits capture. For outgoing calls, `media_prepared`
permits negotiation during ringback; the carrier route, call timer and recording
availability still wait for Telecom's active state. Incoming calls require answer
confirmation. `CloudWebRTCSignal` implements the
v1 JSON SDP/ICE envelope. Each negotiation has a new UUID, remote ICE is bounded to
128 candidates, and callbacks are fenced by connection, call and session identity.
Only an agent reconnect triggers a new offer; a late Watch connection does not.
Connected audio requires both native DTLS readiness and the agent's session-scoped
`webrtc_ready` after its verified Android carrier route is ready. Peer reconnect and failed ICE
use the existing bounded media recovery. Hangup,
CallKit deactivation, mute and system route changes retain the existing lifecycle.
Native WebRTC owns the device audio, Opus, 20 ms packetization, FEC/DTX, AEC, PLC and
jitter handling; it never feeds the legacy PCM resampler/time-pitch graph. Stats
contain only numeric media counters and session identity, never SDP or ICE secrets.

Local VoWLAN uses host-only ICE and the same native peer. After the SDP exchange,
iPhone polls authenticated `POST /api/calls/webrtc/status` with `version: 1`,
`call_uuid`, `generation`, and `session_id`. Responses must echo the exact identity
and report `preparing`, `ready`, `failed`, or `closed`. ICE connectivity alone is
not readiness. Startup and recovery are bounded to 30 seconds; teardown cancels
polling and posts the same identity to `/api/calls/webrtc/stop`. A failed local
session never silently changes to cloud or hangs up the carrier call.

CallKit forwards activation/deactivation once for either transport. User-started
recordings use a call-UUID-bound native processing observer for both directions,
so local/cloud source labels cannot discard local recordings or admit callbacks
from a previous call. Existing recording files and privacy protections are unchanged.
Watch is a companion controller only: it never opens a media socket or captures
microphone audio; mute and local-answer controls reach the iPhone peer.

These changes require a fresh Xcode build/test and real-device acceptance. Source
and simulator checks cannot prove privileged carrier routing or locked/background
CallKit and Watch behavior.

`WebRTCDependency/Package.swift` pins the official `webrtc-sdk/Specs` 144.7559.15
XCFramework URL and SHA-256 (SPM verifies every downloaded binary). The manifest
matches upstream tag `f86eaecba843c8e0fe859d556c7c7831b0d9a132` except for limiting
platform declarations to iOS, avoiding the upstream Swift 5.9/visionOS v26 manifest
incompatibility. `WebRTCDependency/LICENSE` is the SDK's bundled BSD license (also copied into the app bundle)
and must accompany redistribution. `THIRD_PARTY_NOTICES.txt` includes the pinned
SDK dependency notices; the BSD license, patent grant, and supplemental notices are bundled with the app. Engine source revision:
`30d5e63ae91da483e06577b5c35ee91cc5e5c3db`.

`CloudWebRTCTests` exercises the actual native peers with deterministic 440 Hz
input through a test-only audio-device adapter, verifies Opus RTP and audible
PCM output, and tests signaling identity and authenticated ICE request shaping.
The optional TURN test requires `AIRSIM_WEBRTC_TURN_CONFIG` pointing to a private
JSON file with `ios_url`, `username`, and `credential`; it forces relay candidates.
Never commit that file. Physical CallKit/headset routing and real carrier calls
still require separately authorized device testing.

## Standalone-only local control

Local requests are HMAC-authenticated over Wi-Fi VoWLAN. An unavailable local API has no destination URL; USB ECM and the fixed QDC507 address are removed. Live Activity call buttons open AirSIM through the existing typed call-action URL. The app checks the current live call ID before acting; a stale activity cannot control a different or ended call. Legacy activity transport values decode as unavailable without discarding the rest of the activity payload.
