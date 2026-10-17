# AirSIM — Cross-device Calls, SMS, and VoWLAN for Android, iPhone, and Apple Watch

[![Android Standalone](https://img.shields.io/badge/Android-Standalone%20APK-3DDC84?logo=android&logoColor=white)](android-standalone/README.md)
[![iOS](https://img.shields.io/badge/iOS-16.3%2B-000000?logo=apple&logoColor=white)](iOS/README.md)
[![watchOS](https://img.shields.io/badge/watchOS-10%2B-000000?logo=apple&logoColor=white)](iOS/README.md)
[![Android AVF](https://img.shields.io/badge/Android%20AVF-Linux%20arm64-FCC624?logo=linux&logoColor=black)](module/packaging/README.md)
[![Apps release](https://img.shields.io/badge/Apps-v0.9.7.1-2563EB)](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1)
[![Android 10–13 recommended hotfix](https://img.shields.io/badge/Android%2010–13-Hotfix_Recommended-3DDC84)](docs/releases/0.9.7.1-android10-13.md)
[![AVF Agent release](https://img.shields.io/badge/AVF%20Agent-v0.4.6-0F766E)](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6)
[![Cloudflare Relay](https://img.shields.io/badge/Relay-airsim--push.remotepilot.site-F38020?logo=cloudflare&logoColor=white)](https://airsim-push.remotepilot.site/healthz)
[![Project status](https://img.shields.io/badge/status-active%20development-1f6feb)](#project-status)
[![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-7c3aed)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/kai-wu-cortex/AirSIM?style=flat&logo=github&label=Stars)](https://github.com/kai-wu-cortex/AirSIM/stargazers)

**AirSIM is a source-available cross-device communication project that uses an Android phone as the cellular endpoint, allowing an iPhone and Apple Watch to make and receive calls and send and receive SMS remotely.** The recommended Android Standalone APK handles Android Telecom, SMS, device identity, Relay heartbeats, cloud commands, and media orchestration in one foreground service. It requires no AVF Linux, Terminal, Debian, `8575/8576`, or `airsim-installerd`. Apple clients use CallKit, PushKit, ActivityKit, and VoWLAN; an optional Cloudflare Workers Relay provides public-network events, APNs push, command queues, and media relay.

AirSIM is a source-available, noncommercial cross-device calling and messaging project that connects Samsung Android, iPhone, Apple Watch, Android AVF Linux, CallKit, PushKit, VoWLAN, APNs, and Cloudflare Workers.

> This repository contains source code, build scripts, and deployment documentation. It does not provide a reusable Apple Developer identity, production APNs keys, or Cloudflare account resources. The upstream maintainer runs an AirSIM Relay for testing their own signed builds; it is not a public service for third-party Bundle IDs and has no availability commitment. Anyone re-signing the app must deploy their own Relay. This project cannot replace emergency calling. Production use requires joint acceptance testing on the intended Samsung phone, iPhone, and Apple Watch.

> [!IMPORTANT]
> This project is intended for personal learning, research, experiments, and other noncommercial uses. Commercial use, paid services, commercial product integration, and anticipated commercial applications are not authorized. Commercial licensing requires separate prior written permission from the copyright holder. See the [PolyForm Noncommercial License 1.0.0](LICENSE). Because commercial use is prohibited, this is **source-available**, not open source under the OSI definition.

**Tags / Topics:** `Samsung Android` · `iPhone` · `Apple Watch` · `CallKit` · `PushKit` · `VoWLAN` · `Android AVF` · `Cloudflare Workers` · `APNs` · `SwiftUI` · `Go`

## About this fork

This fork at [se0nghe0n/AirSIM](https://github.com/se0nghe0n/AirSIM) includes the rooted Q25 setup, complete English app UI and basic guides, and cloud-call reliability fixes. The original project and its attribution are retained below.

- English is the default app language. The existing language preference and Chinese option remain available; caller names, SMS content, and operating-system messages keep their original language.
- The Q25 Android package is `com.airsim.phonecontrol.q25`. Apple signing and Relay settings in this branch are configured for the fork owner; use your own identities and credentials for a separate installation. A `workers.dev` Relay endpoint can be used without a custom domain.
- Native WebRTC/Opus cloud calls are available for rooted Android Standalone and iPhone, with authenticated signaling and expiring TURN credentials. See the [WebRTC setup and validation guide](docs/webrtc.md). Older clients and Apple Watch retain PCM.
- The legacy iPhone PCM receive buffer adapts to observed delivery stalls and preserves queued speech during recovery. Native WebRTC uses its own playout and bypasses that PCM buffer. Local tests do not establish real carrier-call quality.
- Release links below point to upstream binaries. They do not include this fork's additional changes; build this branch to use them.

## Buy Me A Coffee
<img width="300" alt="05d04c887d99c9df849f81b1cff672dd" src="https://github.com/user-attachments/assets/91620ed1-727e-4a81-9d99-d20d6d55bb58" />

**The upstream project's release attracted more traffic than its test server could handle and exceeded its limits. If you enjoy the software, you can support its author.**

## Discussion group
<img width="362" height="358" alt="image" src="https://github.com/user-attachments/assets/402158bb-2263-408c-a85f-00b34a16b1bd" />
https://t.me/+TRDazm-qnXlhNGRl

## Core capabilities

- **Cross-device calls:** Dial, answer, reject, hang up, mute, and send DTMF on iPhone or Apple Watch, with the Samsung Android phone carrying the cellular call.
- **Cross-device SMS:** Synchronize SMS state, send messages, and notify Apple clients through APNs.
- **CallKit and PushKit:** Present the iPhone system incoming-call UI, with VoIP push wake-up and incoming-call reporting.
- **Direct local VoWLAN:** Use HMAC-authenticated control and PCM links when iPhone and Samsung share a LAN or Samsung hotspot.
- **Direct VoBLE Bluetooth (VoBLE branch):** Select Bluetooth as an independent connection mode. Authenticated BLE GATT carries call control and bidirectional audio without Wi-Fi, Relay, PushKit, or cloud parameters.
- **Single Android APK:** Includes the Agent and Bridge, removing the need for AVF Linux, Terminal, Debian, or an installer.
- **Cloud Relay:** A separately deployed Cloudflare Worker, KV, and Durable Objects connect the built-in Android Agent and Apple clients.
- **Visible connection modes and diagnostics:** The Android home screen and iOS settings show VoWLAN/cloud status. iOS can validate push credentials, AirSIM Relay identity, device registration, and an AVF Agent heartbeat within 90 seconds.
- **Automatic HyperOS setup:** If the default-phone-role screen is unavailable, an authorized Shizuku connection can configure the role for the APK.
- **Android call audio bridge:** Shizuku `UserService` and system `TYPE_TELEPHONY` routes forward bidirectional PCM in memory without saving call audio.

## Architecture

The recommended Standalone architecture runs the Bridge and Agent in one APK:

```text
iPhone / Apple Watch
        │  VoWLAN, VoBLE, or Cloudflare Relay
        ▼
Android AirSIM Standalone APK
        ├─ Built-in Agent: identity, heartbeats, commands, and media orchestration
        ├─ Android Telecom / SMS
        └─ Shizuku call PCM bridge
```

The legacy AVF architecture remains available for compatibility and fallback, but is no longer recommended for new installations.

The upstream maintainer uses `https://airsim-push.remotepilot.site`, allowing only `com.eric3u.airsim`. DJOneHub continues to use `https://push.remotepilot.site`. The domains have separate Workers, KV, Durable Objects, and Dashboard tokens; do not reuse them across services. Other signing identities require their own Relay endpoints, Cloudflare resources, and APNs credentials.

Each call selects VoWLAN or Relay when established and keeps that transport until the call ends, preventing media and control from switching paths mid-call.

### VoBLE Bluetooth mode

VoBLE is a mode alongside VoWLAN and cloud Relay, not a required component of Wi-Fi operation. After selecting “Direct Bluetooth,” the iPhone and Android pair using an ephemeral key confirmed by a one-time short code. Both control messages and G.711 μ-law 8 kHz mono audio use AES-256-GCM authenticated encryption. A call binds to the same `call_id` and generation to prevent reconnection from affecting another call. Brief disconnections may recover only within three seconds, for the same call and generation.

Bluetooth mode carries only AirSIM control and call audio. **It does not share Android cellular internet with iPhone through Bluetooth PAN.** Use an Android hotspot, Wi-Fi, or the iPhone's own cellular connection for internet access. iOS still uses CallKit to present and manage calls, but local Bluetooth needs neither PushKit nor Relay. iOS does not guarantee BLE background wake-up after a user force-quits the app; reopen AirSIM before receiving calls. Apple Watch can mirror iPhone CallKit incoming calls and control state, but actual audio routing is determined by iPhone/watchOS. The Watch does not connect directly to Android BLE.

See the [VoBLE design](docs/superpowers/specs/2026-10-12-voble-bluetooth-call-design.md) and [VoBLE device test matrix](docs/voble-real-device-test-matrix.md) for implementation and acceptance boundaries.

## Repository layout

| Directory | Component | Responsibilities |
| --- | --- | --- |
| [`android-standalone`](android-standalone/README.md) | Android Standalone APK | Recommended entry point; combines Agent, Telecom, SMS, VoWLAN, Relay, and media orchestration in one APK |
| [`android/phone-control-app`](android/phone-control-app/README.md) | Samsung Android control app | Default phone role, Android Telecom, pairing, SMS, VoWLAN, and foreground service |
| [`android/phone-audio-bridge`](android/phone-audio-bridge/README.md) | Samsung call audio bridge | Bidirectional PCM through Shizuku, restricted to AVF private interfaces |
| [`module/module-agent`](module/module-agent/README.md) | Android AVF Agent | Control API, device status, Relay heartbeats, commands, and media orchestration |
| [`module/avf-installerd`](module/avf-installerd) | AVF recovery installer | Signed Debian package verification, health checks, and failure rollback |
| [`module/packaging`](module/packaging/README.md) | AVF Debian releases | Single `arm64` package, systemd units, and bootstrap scripts |
| [`iOS`](iOS/README.md) | iPhone / Apple Watch app | CallKit, PushKit, VoWLAN, SMS, Live Activities, and call media |
| [`push-relay-worker`](push-relay-worker/README.md) | Cloudflare Relay | Device registration, APNs, cloud commands, Dashboard, and public-network media |
| [`docs`](docs) | Protocol and design documentation | VoWLAN / VoBLE design, Samsung hotspot pairing protocol, and security boundaries |

## Quick start

### Documented release baseline

| Component | Version or address |
| --- | --- |
| Android Standalone / AVF Bridge · Android 10–13 hotfix APK | [`v0.9.7.1 (81)`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1); Standalone recommended |
| iPhone / Apple Watch app | `0.9.7 (81)`; unsigned IPA supplied with [v0.9.7.1](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1); TestFlight uploaded separately |
| Android AVF Linux Agent | [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6) (Debian package `0.4.6-1`) |
| AirSIM Relay | `0.2.1` · [`https://airsim-push.remotepilot.site`](https://airsim-push.remotepilot.site/healthz) |
| DJOneHub Relay | `https://push.remotepilot.site` (separate service; must not be used by AirSIM) |

### Application release packages

#### Android 10–13 hotfix

[AirSIM v0.9.7.1 — recommended Android 10–13 hotfix](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1). For new installations, choose `AirSIM-Android-Standalone-0.9.7.1-Android10-13.apk`, which includes the Agent and needs no AVF Linux. Official signed builds can upgrade an existing Standalone installation signed with the same certificate while preserving data; versionCode increases from 80 to 81. Do not uninstall or clear pairing data first. Debug or third-party re-signed builds using another certificate cannot replace the existing app directly. Legacy AVF deployments can use the matching AVF Bridge APK without updating the Linux Agent.

This hotfix addresses startup, log/crash-report reading, permission requests, and VoWLAN, Relay, and PCM read crashes caused by Java methods missing on older systems. It replaces `ByteArrayOutputStream.toString(Charset)`, `InputStream.readNBytes`, and `Collection.toArray(IntFunction)`, and checks compiled output to prevent their return. It does not lower `targetSdk` or remove permissions or Bluetooth functionality. Targeting Android 10–13 does not prevent installation on newer systems or guarantee OEM call-audio support.

The hotfix was installed on Redmi M2004J19C (Android 12) without clearing data, and the user confirmed VoBLE pairing. In the latest recorded two-device cloud-call test, the user reported that the call screen no longer reappeared after hang-up and audio was steadier. The iOS pairing screen adds a local-mode switch scoped to that pairing operation, and cloud asynchronous hang-up races are addressed. vivo Android 11, Android 10/13, and realme have not completed this hotfix's device acceptance; SMS and bidirectional audio still require per-model testing. Public IPAs need re-signing, and a TestFlight upload does not mean review approval. See the [release notes](docs/releases/0.9.7.1-android10-13.md).

[AirSIM Apps v0.9.7](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7) introduced independent VoBLE mode, available-route dialing priority, paired-device management, and current SIM identity refresh. It addresses Bluetooth audio, reconnection, and hang-up races, and adds Android default calling-SIM selection, crash-report sharing, and Shizuku startup guidance. The Release provides AVF Bridge and Standalone APKs plus an unsigned IPA; signed iOS build `80` was uploaded to TestFlight separately. See the [v0.9.7 release notes](docs/releases/0.9.7.md) for the summary, acceptance boundaries, installation, and re-signing.

### 1. Prepare the development environment

- An Android test phone supporting Android Telecom, Shizuku, and wireless debugging. Standalone does not require Android AVF Linux.
- Android builds: JDK 17, Android SDK Platform 35, and Build Tools 35.
- Apple builds: Xcode; minimum targets are iOS 16.3 and watchOS 10.
- Agent builds: Go 1.24.
- Relay deployment: Node.js 20 or newer, Cloudflare Wrangler, and your own Cloudflare and Apple Developer resources.

### 2. Build the Android Standalone APK

```sh
./android-standalone/test.sh
./android-standalone/build.sh
```

After installing, make AirSIM Standalone the default phone app, start Shizuku, and authorize AirSIM. On Xiaomi HyperOS, if the system role-selection page is unavailable, the app configures it after Shizuku authorization. See the [Android Standalone documentation](android-standalone/README.md).

### 3. Optional: install the legacy Android AVF Agent

For new devices, prefer the Standalone APK above. Use this AVF process only for legacy compatibility or fallback.

For first installation, open Android AVF Linux Terminal and confirm an interactive Debian prompt before running the following command (`pipefail` exposes download failures). Devices already on `0.4.4-1` must use the one-time key migration below, not the first-install command:

```sh
bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'
```

Devices on `0.4.4-1` must perform a one-time signing-key migration in the same AVF Terminal. The script checks the old package digest, verifies the new signature, retains the old package, and attempts rollback on failure. **Do not select “Update to latest” in the app yet: the old installer does not trust the new public key.**

```sh
curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 -o /tmp/airsim-rotate-v0.4.5.sh https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.5/rotate-avf-key.sh
printf '%s  %s\n' '9ae6b8c69d5d9877638a50240282a67d06b73d807dba444c816c5efb9c5ec04d' /tmp/airsim-rotate-v0.4.5.sh | sha256sum -c - && sudo sh /tmp/airsim-rotate-v0.4.5.sh
```

The app only copies the command; paste and run it in Debian Terminal. The installer accepts only the matching `arm64` Debian package with its Ed25519 signature. **Installation is complete only when both Agent and installerd health checks pass.** The repaired bootstrap first restores services when `current.deb` exists and reinstalls from that package if necessary, allowing recovery of an existing installation. Then run `sudo airsim-avf-pair` and save the control token in the Samsung app. Use the dynamically assigned guest private address for this device, not an example subnet. Later updates, repairs, and rollbacks use the separate `airsim-installerd`. For “Not paired” or unavailable `8576`, see the [AVF installation and non-destructive troubleshooting guide](docs/AVF_INSTALL_GUIDE.md); see [AVF Debian releases](module/packaging/README.md) for package details. Source fixes must be re-signed and published as GitHub Release assets before the online installation commands can deliver them.

If `apt` reports incompatible `udev` and `libudev1` versions, simulate dependency repair as described in the installation guide first. Do not directly run `apt --fix-broken install`, which might remove system components. The repaired bootstrap detects existing Debian dependency failures before Agent installation.

DJOneHub can remain in the same AVF guest. AirSIM uses dedicated Agent/installer ports `8575` / `8576`, leaving DJOneHub's `7575` untouched. Before installing, confirm the GitHub Release includes the port migration. Older online packages still listen on `7575`; **do not run older commands in an environment shared with DJOneHub**.

See the [0.4.5 release notes](docs/releases/0.4.5.md) for fixes, key migration, and acceptance steps.

### 4. Configure and sign the iPhone / Apple Watch app

```sh
open iOS/AirSIM.xcodeproj
```

Use your own Apple Developer Team, assign unique Bundle IDs to the main app, Watch app, and Live Activity Extension, and regenerate provisioning profiles. `com.example.airsim` is a placeholder and cannot be used directly for release or APNs. See the [iOS / watchOS documentation](iOS/README.md) for signing, CallKit, PushKit, and APNs topic relationships.

### 5. Optional: deploy Cloudflare Relay

Upstream maintainer deployment:

| Item | Documented value |
| --- | --- |
| Worker | `airsim-push-relay` |
| AirSIM URL | `https://airsim-push.remotepilot.site` |
| Allowed main Bundle ID | `com.eric3u.airsim` |
| DJOneHub URL | `https://push.remotepilot.site`, kept separate |
| Required Secrets | `APNS_P8`, `DASHBOARD_TOKEN`, stored only as Cloudflare Secrets |

As of 2026-10-08, AirSIM and DJOneHub `/healthz` returned their respective service names. The AirSIM Dashboard returned `401` anonymously and `200` with the correct Bearer token. At that check, the new AirSIM environment had no registered devices, so real PushKit, APNs, Agent heartbeats, and cloud PCM remained unvalidated.

This table is not an offer of public access. When re-signing with your own Apple Developer Team and Bundle ID, deploy your own Relay:

```sh
cd push-relay-worker
npm ci
cp wrangler.example.toml wrangler.toml
npm test
npm run check
npx wrangler deploy --dry-run --config wrangler.toml
```

Before deployment, create your own KV, configure Durable Objects and a custom domain, and add `APNS_P8` and `DASHBOARD_TOKEN` as **Worker Secrets**, never in Git or `[vars]`. See the [Cloudflare Relay deployment guide](push-relay-worker/README.md).

## Apple signing requirements

AirSIM does not include the original author's Apple Developer Team, App IDs, certificates, or provisioning profiles. Every user must:

1. Replace main app `com.example.airsim` with a unique Bundle ID they control.
2. Set the Watch app and Live Activity Extension to that main Bundle ID plus `.watchkitapp` and `.liveactivity`, respectively.
3. Re-sign with their own Apple Developer Team, development/distribution certificate, and provisioning profiles.
4. Set Relay `ALLOWED_BUNDLE_ID` to the same main app Bundle ID.
5. Validate PushKit, notification, Watch, and Live Activity topics separately in APNs sandbox and production.

Replacing only the certificate while retaining someone else's Bundle ID does not grant access to that App ID or its APNs topics.

## Documentation

| Document | Use |
| --- | --- |
| [Android Standalone APK](android-standalone/README.md) | Recommended installation, builds, signing, HyperOS permissions, migration, and device acceptance |
| [Legacy Samsung Android control app](android/phone-control-app/README.md) | AVF compatibility, default phone role, pairing, and OEM compatibility |
| [Samsung call audio bridge](android/phone-audio-bridge/README.md) | Shizuku bridge builds, operation, and PCM boundaries |
| [Android AVF Agent](module/module-agent/README.md) | Agent configuration, API, security, and startup probes |
| [AVF Debian releases](module/packaging/README.md) | `.deb` builds, signing, bootstrap, upgrades, and rollback |
| [AVF installation and non-destructive troubleshooting](docs/AVF_INSTALL_GUIDE.md) | Terminal, control tokens, two-service health checks, and startup-conflict recovery |
| [iOS and watchOS](iOS/README.md) | Xcode, Bundle IDs, Apple signing, CallKit, PushKit, and device tests |
| [Cloudflare Relay](push-relay-worker/README.md) | Wrangler, KV, Durable Objects, APNs, Secrets, and custom domains |
| [Native WebRTC cloud calls](docs/webrtc.md) | Q25/iPhone audio, TURN setup, compatibility, protocol, and validation |
| [VoWLAN design](docs/2026-09-11-vowlan-design.md) | Local transport design and protocol boundaries |
| [VoBLE device test matrix](docs/voble-real-device-test-matrix.md) | Bluetooth setup, automation results, device matrix, and outstanding hardware acceptance |
| [Samsung hotspot pairing protocol](docs/samsung-hotspot-pairing-protocol.md) | Pairing, key derivation, HMAC, and replay protection |
| [Codex deployment assistance](codex.md) | Project-wide build, validation, and deployment rules for Codex |
| [Claude deployment assistance](claude.md) | Project-wide operating order and safety constraints for Claude |
| [General LLM context](LLM.txt) | Machine-readable project contract for other AI tools |

## Project-wide validation

```sh
./android-standalone/test.sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
(cd push-relay-worker && npm test && npm run check)
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Automation does not replace end-to-end acceptance on Samsung Android, iPhone, Apple Watch, AVF Linux, APNs sandbox/production, and public-network Relay.

## Security and privacy

- AVF Agent, installer, and PCM ports may bind only to the device's internal private network or loopback.
- VoWLAN control requests must validate timestamps, nonces, and HMAC; pairing keys reside in platform secure storage.
- Never commit device secrets, Agent tokens, APNs `.p8`, `DASHBOARD_TOKEN`, signing private keys, real phone numbers, or production configuration.
- Call PCM is processed only in memory and on the network, never saved to disk. Logs must omit PCM, complete SMS messages, push tokens, and authentication material.
- Emergency calls must use system telephony; AirSIM is not an emergency communications guarantee.
- The Android app cannot bypass OEM firmware or system-signature restrictions to enable hidden or removed AVF Linux features.

## Project status

AirSIM is actively developed. The repository combines Android Standalone, legacy AVF Agent/Installer, iOS/watchOS, and Cloudflare Relay sources with local automated validation. Android Standalone has recorded device verification on Xiaomi HyperOS for the default phone role, VoWLAN pairing, and bidirectional call audio. Each deployer must still validate Apple signing, additional Android OEMs, background push, and long-term stability in their own environment.

## Project trends

[![AirSIM Star History Chart](https://api.star-history.com/svg?repos=kai-wu-cortex/AirSIM&type=Date)](https://www.star-history.com/#kai-wu-cortex/AirSIM&Date)

## License

AirSIM uses the [PolyForm Noncommercial License 1.0.0](LICENSE):

- Personal learning, research, experiments, testing, hobby projects, and other noncommercial uses listed in the license are permitted.
- Viewing, modification, and redistribution for noncommercial purposes are permitted with the license and [Required Notice](NOTICE) included.
- **Commercial use and anticipated commercial applications are not permitted.** Commercial authorization requires separate written permission from the copyright holder.
- The license includes a patent license to the extent contributors can grant one, but provides no warranty.
- Third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

The prohibition on commercial use means this project does not satisfy the OSI Open Source Definition. Describe AirSIM as “source-available,” rather than OSI open source.
