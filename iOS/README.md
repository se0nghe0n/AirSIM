# AirSIM iOS and watchOS

This directory contains the iPhone app, Apple Watch app, Live Activity, and shared models for a compatible Android phone endpoint. Clients can connect directly over VoWLAN, or use a separately deployed Cloudflare Relay for remote calls and SMS.

The documented app build is `0.9.7 (81)`, supplied as an unsigned IPA with [Apps v0.9.7.1](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1). The upstream maintainer separately uploads production builds through Xcode to TestFlight; upload, processing, and review must be checked separately. The maintainer's `com.eric3u.airsim` build uses `https://airsim-push.remotepilot.site`; changing the Bundle ID requires your own Relay and APNs credentials.

## Xcode project

Open:

```text
iOS/AirSIM.xcodeproj
```

Main targets:

- `AirSIM`: native UIKit iPhone / iPad app (`AirSIMAppDelegate`, `AirSIMSceneDelegate`, and `RootViewController`)
- `AirSIMWatchApp`: Apple Watch App
- `AirSIMLiveActivityExtension`: Lock Screen and Dynamic Island Live Activities
- `AirSIMTests`: transport selection and protocol-boundary tests

The `AirSIM` target is organized into feature groups backed by matching folders under `iOS/AirSIM/`. Add new files to the group that owns the feature. Each screen family has one TCA feature (`*Feature.swift`) in its folder, next to its view controllers (one screen per file) and the small value types that prepare its rows:

- `App`: application/scene delegates, `AppModel`, app settings, the root `AirSIMFeature` reducer and its live store, its `AirSIMClient` dependency and `AirSIMSnapshot` projection, URL and tab routing, and `RootViewController`
- `UI`: shared UIKit building blocks (`ObservingViewController`, `PhoneTableController` and `PhoneRow`, buttons, labels, avatars, backdrops, empty states, alert and sheet helpers, and the `UIStackView` and `addPinnedSubview` layout helpers)
- `Agent`: Android Agent API client, wire models, connection mode and paired-device preferences
- `Pairing`: Samsung one-time encrypted pairing
- `VoWLAN`: local discovery, HMAC request signing, Wi-Fi-pinned HTTP transport
- `Cloud`: PushKit/Relay registration and commands, cloud call session, WebRTC peer
- `Call`: CallKit, call lifecycle, audio session, virtual-call TTS, background standby and call notifications
- `Phone`: one subgroup per screen family (`Dial`, `Recents`, `Messages`, `Contacts`, `ActiveCall`) plus `ContactDirectory` and the local history and contact stores
- `Recording`, `Settings`, `Diagnostics`, `LiveActivity`, `Watch`: call recording, setup/settings, the Agent trace recorder (no in-app switch or viewer; see [Cloud audio startup diagnostics](../docs/cloud-audio-startup.md#diagnostics)), Live Activity and Watch coordination on iPhone
- `Previews`: DEBUG preview fixtures

`Info.plist`, `AirSIM.entitlements` and `AppIcon.icon` stay at the `AirSIM/` root because build settings reference those paths.

### Features and screens

The root `AirSIMFeature` holds the backend projection as `@Shared var snapshot: AirSIMSnapshot` and is its only writer. It scopes one child feature per tab and one for the call screen (`DialFeature`, `RecentsFeature`, `MessagesFeature`, `ContactsFeature`, `SettingsFeature`, `ActiveCallFeature`). Children own their own children, such as `RecordingsFeature` under Recents, `ComposerFeature` under Messages and `PairingFeature` under Settings. A feature that shows backend data receives the snapshot as a `SharedReader<AirSIMSnapshot>` in `init(snapshot:)`, keeps it `fileprivate` and exposes presentation-ready members derived from it. Features run their own `AirSIMClient` effects. A request that belongs to another feature, such as calling back or messaging from Recents, is a `delegate` action that the root or the owning parent handles.

Each screen is a view controller marked `@ViewAction(for:)` with its feature and given a scoped `StoreOf<Feature>`. It reads `store` members in `render()`, which `ObservingViewController` runs again whenever state it read changes while the screen is visible. It writes only view actions through `send(_:)`, including lifecycle actions such as `.appeared`. A screen with no state of its own, such as contact details or the recent-call card, uses its parent's store. Pushes and sheets of persistent child state stay UIKit-owned with a scoped store; state drives only the composer, contact picker, call keypad, alerts, the call window, the selected tab and the open conversation. UIKit-only effects such as haptics, the pasteboard, share sheets and confirmation dialogs stay in the controller.

A view controller file reads top to bottom in `// MARK:` sections: Store, Views, Lifecycle, Rendering, Rows, Layout, Navigation, Actions and UIKit delegates. Layout numbers it reuses go in a `private enum Metrics`, and its `#Preview`s close the file under `#if DEBUG`.

Swift sources follow `iOS/.swift-format` (4-space indent, 120 columns, one argument per line when a call wraps, no `;` between statements). Run `xcrun swift-format format -i -r iOS/AirSIM iOS/AirSIMTests iOS/AirSIMWatchApp iOS/AirSIMLiveActivityExtension iOS/Shared` before committing, and keep a blank line between declarations that span several lines.

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
- Cloud mode queries Relay status once on foreground entry and again when cloud dialing is needed. In automatic mode that dial-time query starts together with the VoWLAN check unless VoWLAN is currently verified, and is cancelled unread when VoWLAN carries the call. Dynamic Island waits for one status query before displaying a call, including background incoming calls. Local mode does not query Relay; VoWLAN loss and background standby updates do not start periodic cloud queries, avoiding repeated quota consumption.
- Four-stage Cloud Self-Test in Settings: local configuration (push credentials), Relay identity, device registration, and Agent heartbeat
- Local call history, swipe-to-delete, and deletion from details

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
7. In “Settings → Cloud Self-Test,” tap “Run Cloud Self-Test.” All four checks must pass for cloud control readiness. “Relay Identity” rejects DJOneHub and other services; “Agent Heartbeat” requires a report from the Standalone Agent within 90 seconds. The self-test does not dial or send SMS.

### Manage paired Android devices

Below “Settings → Samsung Connection → Pair Android Phone,” the paired-device list shows current device names, numbers, and VoWLAN/cloud status, with individual deletion confirmation. Offline history stores only device ID, name, and Agent type, not phone numbers. If a number cannot be read or is not provided by the SIM, it shows “Number not provided” without filling in a historical number.

Deletion removes the local list entry and manual binding for that device and retains a marker preventing automatic reconnection. Other devices, call history, and SMS are unaffected. Deleted devices must be explicitly paired again and cannot be restored by advertising or stale cloud status.

Reconnection uses current advertisements and authentication checks rather than a cached peripheral UUID. Newer Android APKs support authenticated BLE `device_info`; older APKs do not substitute historical VoWLAN/Relay numbers. Standalone cloud heartbeats and local health checks read the current calling SIM, not the number saved at initial pairing. Saved retired Agent records remain readable without becoming a supported runtime. Existing Apple pairing credentials, SMS history and recordings are preserved.

## Build and test

The app and its Previews can build with the iOS 27.1 SDK. Siri `ToolIntent` conformances require the iOS 27.3 SDK (AppIntents module version 301.2.7.2 or newer) and are conditionally compiled; ordinary App Intents and App Shortcuts remain available with the older SDK. Running on iOS 27.3 alone does not enable Siri tools in an app built with the older SDK. The separate `AirSIMSiriEvaluations` target requires the newer SDK as well.

If multiple Xcode versions are installed, the Xcode app opened for Previews determines their SDK; `xcode-select -p` only identifies the command-line default. Set `DEVELOPER_DIR` explicitly when comparing command-line builds with Canvas results.

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

## Versions and TestFlight

`iOS/Config/Version.xcconfig` is the only source of the version for the iPhone app, Watch app and Live Activity extension. Do not set the version or build in Xcode's General tab; that writes target overrides, and `version.sh` refuses to run while they exist.

- `MARKETING_VERSION` is `{ISO week-year, two digits}.{ISO week}.{N}`, for example `26.45.1`. `N` counts uploads in that week from 1 and restarts each Monday (Asia/Seoul; override with `AIRSIM_VERSION_TIMEZONE`). Weeks have no leading zero.
- `CURRENT_PROJECT_VERSION` is one integer that only increases, across all versions.

Each upload reserves its numbers on the Git remote, so any Mac can upload without colliding:

```sh
iOS/scripts/version.sh next      # what the next upload would get
iOS/scripts/testflight.sh        # reserve, commit, push, archive and upload
```

`testflight.sh` runs `version.sh bump`, which fetches, fast-forwards or rebases the current branch, commits the new `Version.xcconfig`, and pushes that commit atomically with an annotated tag `ios/v<version>-<build>`. These tags are the shared registry: the next build is one more than the highest tag on any branch. When two Macs race, the remote rejects the second push and that Mac recomputes. A failed upload leaves a gap in the build numbers; retry the same reserved build from its commit with `testflight.sh --skip-bump`.

The script archives the `Release` configuration (APNs `production`) and uploads with `manageAppVersionAndBuildNumber` off, so Xcode keeps the reserved numbers. It signs with the Apple ID signed in to Xcode, or with an App Store Connect API key when `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` are set. Archives stay in the ignored `iOS/build/testflight/`. An upload needs an App Store Connect app record for the main Bundle ID, and App Store Connect must finish processing before testers see it.

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

## Outgoing cloud call setup

Placing a cloud call does not change the wire contract; the iPhone only stops waiting where it does not have to.

- Relay requests that follow each other within 30 seconds share one HTTPS connection (`RelayHTTPClient`): the status check, the dial command, its result polls and the call's TURN request. The session is ephemeral and keeps no cookies, cache or credentials. After a longer pause the next request opens a new connection, as every request did before. A request that fails because its connection was already closed is sent once more; Relay requests are reads, registrations, or commands deduplicated by `command_id`.
- A signed VoWLAN health check fails at once when the iPhone has no interface that could reach a private address: nothing but loopback and cellular (`pdp_ip*`) holds an IPv4 address. The result is the same `unavailable` state its 3-second timeout produced. With Wi-Fi, an Android or iPhone hotspot, Ethernet or a VPN the check runs as before, and VoWLAN keeps its priority.
- The dial result is polled after 100, 200 and 300 ms, then every 500 ms. SMS, DTMF and call-history commands keep 500 ms throughout.
- When the Relay accepts the dial command it names the call. The iPhone then requests TURN credentials, initializes native WebRTC and opens the call's signaling socket while the Android phone starts dialing. Nothing is sent on that socket: `answer`, the owner join, still follows the completed dial. Until then the session has no call, is not answered and starts no peer. A dial that fails, times out, is cancelled or is superseded closes the socket and drops the credentials; so does a terminal status on that socket, a call answered in the meantime, or 45 seconds without a result.
- For an outgoing call the first resend after `answer_pending` comes after 300 ms and the second completes the regular second, so the join is never confirmed later than with one-second resends. Incoming calls keep one second.

### Incoming cloud preparation

After CallKit successfully reports an incoming call, the iPhone prepares TURN credentials and native initialization while the phone rings. The signaling socket waits for explicit acceptance because a normal Relay socket can replace an existing same-role owner. It sends no answer/ownership control, starts no WebRTC peer, and does not access the microphone or recording. Answering adopts that exact credential preparation; rejection, expiry, CallKit teardown, another call or a VoWLAN answer releases it. A changed generation, Relay endpoint or bearer credential cannot reuse old preparation.

Cold-launch startup also handles CallKit activation arriving before cloud answer confirmation: either completion order can arm startup, but the peer still waits for Android's answer acknowledgement and CallKit activation. These changes do not open the Android carrier path before ACTIVE; real ringback capture and physical startup latency remain separate device acceptance gates.

### Measuring setup time

Each outgoing dial writes its phases to the unified log, with milliseconds since the dial started:

```sh
log stream --predicate 'subsystem == "com.example.airsim.call-setup"'
```

```text
dial=3 phase=dial_started elapsed_ms=0
dial=3 phase=vowlan_decision elapsed_ms=2 vowlan=not_ready
dial=3 phase=cloud_status_done elapsed_ms=180 status=overlapped
dial=3 phase=enqueue_accepted elapsed_ms=260
```

The phases are `dial_started`, `vowlan_decision`, `cloud_status_done`, `enqueue_accepted`, `prewarm_signaling_connected`, `dial_completed` or `dial_failed`, `signaling_connected` (with `prewarmed=true` when the prewarmed socket was adopted), `answer_pending`, `media_prepared` or `answer_confirmed`, `ice_config_ready`, `peer_started`, `native_connected`, `active` and `audio_ready`. `dial` counts dials since the app launched. A line holds nothing else: no number, call identity, secret, URL, SDP or ICE candidate. Each phase is written once per dial, except `answer_pending`, so a later media rebuild does not rewrite the timeline. The numbers above only show the format; a comparison needs calls on a physical iPhone, before and after.

## Standalone-only local control

Local requests are HMAC-authenticated over Wi-Fi VoWLAN. An unavailable local API has no destination URL; USB ECM and the fixed QDC507 address are removed. Live Activity answer, decline and hang-up buttons use background `LiveActivityIntent` actions. The system executes them in the app process without opening AirSIM; the widget holds no credentials. Existing CallKit transactions control Cloud/system calls, including the cold-launch handler. Local mode resolves a paired VoWLAN endpoint and sends the exact observed call ID. Empty, replaced and ended targets fail; a stale Decline button cannot hang up an answered call. Typed call-action URLs remain compatible with older activities. Legacy activity transport values decode as unavailable without discarding the rest of the activity payload.

Build both the app and Live Activity extension and verify their generated App Intents metadata contains all three actions with background execution. Unit tests exercise intent dispatch, invalid targets, repeated answers and surfaced failures. Locked-screen taps and cold-launch execution on a physical phone remain device acceptance checks.

On iOS 27 and later, Siri and Shortcuts can start an audio AirSIM call through the App Intents `phone.startCall` schema. AirSIM rejects video requests and recipients without a dialable phone number. The intent opens the app and places the call through the same dial path as the keypad. Unit tests cover the number and mode policy; spoken Siri invocation on a physical phone remains a device acceptance check.

Siri and Shortcuts can also draft an AirSIM SMS with the Draft AirSIM SMS intent, which is a Siri tool on iOS 27.3. AirSIM opens its composer with an optional recipient and plain text filled in and never sends without the user, and the "Text with AirSIM" App Shortcut runs it. It adopts no `messages` schema, because that domain must be adopted whole and `messages.sendMessage` would hand stored message bodies to the system. Spoken Siri drafting is also a device acceptance check.

Siri and Shortcuts can also answer, decline or end the current call, mute the microphone, switch the speaker, start or stop recording, send keypad digits, set the connection mode, check the connection, sync messages and open a tab. These actions run without opening AirSIM, except Go to AirSIM Tab. On iOS 27.3 every one of them is also a Siri tool except Check AirSIM Connection and Sync AirSIM Messages, which need AirSIM already running, while Siri may call a tool at any time. AirSIM leaves out actions that would hand SMS bodies to the system (sending messages, read status, message entities), actions SMS cannot honor (edit, unsend), deletion, because it loses data for good, pairing and Relay settings, because they carry security material, and appearance and Live Activity toggles, which add little. Spoken Siri and background execution on a physical iPhone remain device acceptance checks.

## UIKit and TCA presentation

The main app uses native tab, navigation, table, text-input, and sheet controllers.
The Watch app and Live Activity extension retain SwiftUI. No main-app controller
embeds SwiftUI. The official `swift-composable-architecture` package is pinned to
1.26.2; the included `Package.resolved` also locks transitive dependencies, and
`ThirdPartyNotices.txt` is bundled with the app.

`AirSIMFeature` owns tab, deep-link and onboarding navigation. `ActiveCallFeature`
presents the call keypad as a `KeypadFeature` through `@Presents`. `MessagesFeature`
presents the SMS composer as a `ComposerFeature` the same way and runs its send
itself, so closing the composer never cancels an SMS in flight. Alerts are
`AlertState` in Store state. The composer presents its own with `present(item:)`.
The thread and recordings screens present theirs above whatever is on top, so a
late failure never replaces another sheet, and an alert closed from beneath clears
its state. The root alert covers backend errors and failed sends whose screen has
closed. Root presents it above whatever is on top, including the call, so it never
replaces an open sheet; its OK clears only the backend error it showed. The
Messages, Settings, Pairing and Recordings reducers own their draft, progress,
selection and operation states. UIKit controls read scoped Store state and send
view actions. Network, pairing, playback and persistence operations run through
an injected `AirSIMClient`. `AppModel`
remains the existing communications service. Its immutable value snapshots enter
the Store through a cancellable Observation stream, without a polling bridge or a
reference model inside reducer State. Dial commands carry the number atomically;
SMS responses carry an operation ID so old completions cannot clear a newer draft
or dismiss a newly opened composer.

The notification delegate installs cold-launch CallKit and PushKit handlers before
foreground scene creation. Background-only scene connections defer AppModel and
UI construction until foreground entry. Inactive/background audio preparation
remains a synchronous scene-to-service lifecycle call. Scene teardown cancels the
Store snapshot stream. `tel:`, `im:`, Live Activity actions and pending SMS routing
enter the native hierarchy; a composer requested during onboarding waits in Store
state until onboarding completes. The app keeps a single scene; the in-app call
surface uses its own window above the main window, so no sheet or onboarding screen
can cover Accept or Decline. Live Activity URL commands carry their call ID to a
gate against current backend state immediately before execution.

`UIKitPresentationTests` exercises input focus/selection across changing rows,
editor sizing on narrow screens and sheet toolbar preservation. TCA TestStore
coverage includes failed-send drafts, stale completions, mode-change cancellation,
deep-link navigation and snapshot isolation. The component styling inventory and
baseline comparison checklist are in `UIKitStyleAudit.md`. Simulator checks do not
establish real-device pairing, carrier audio, push delivery or proximity acceptance.
The adversarial-review record also covers transition cancellation, modal ownership,
independent contact queries, trace command ordering and stable lazy list content.

## UIKit previews

Use Canvas's **Live** mode for the active-call previews. Mute, speaker, recording,
answer, decline, and end update an isolated in-memory call through the normal
root snapshot action. More uses a native `UIButton.menu`, so UIKit supplies the
Liquid Glass button-to-menu transition, dismissal, and accessibility. The DTMF keys
share the call controls’ diameter and column spacing;
the keypad replaces the upper call content while the same End button stays in place.
The Keypad control becomes Hide. Reduce Motion disables the spatial transitions.
After ending or declining a standalone preview call, **Restart Preview Call**
restores that preview's initial state. These controls never contact a device,
change an audio session, or write a recording.

Each concrete main-app controller and reusable custom view has a named `#Preview`
at the end of its owning Swift file, under `#if DEBUG`. UIKit controllers are
returned directly; reusable components use a small native UIKit canvas for an
explicit display size. These previews cover the main UIKit app.

`AirSIMPreviewSupport.swift` supplies deterministic contacts, calls, messages,
recording metadata and discovered services to in-memory TCA
stores. Its dependency client does not create AppModel or perform file, network,
audio, permission or pairing operations. Fixture dates and the TCA clock are fixed. In an
Xcode preview host, DEBUG lifecycle guards skip live notification/watch/service
bootstrap and the notification delegate's eager discovery/history setup. Normal
app launches still initialize the cold-call handler and history in their original
order before `didFinishLaunching`.
