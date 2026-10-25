# AirSIM whole-project Codex deployment guide

> Current branch migration: native WebRTC and carrier capture/injection share the privileged Android process. There is no supported PCM network/IPC fallback. AVF voice is upgrade-required; Watch is an iPhone audio companion. Legacy bridge source/build instructions below are historical reference, not the current APK workflow. Physical-route and privileged-security gates remain unverified. See [the migration contract](docs/webrtc-only-migration.md).


This document gives AI coding agents the source of truth, build order, deployment boundaries, and security constraints for the whole AirSIM repository. Before starting a task, read the root `README.md`, then the README and actual source of the component being changed. For AVF install, pairing, or recovery, also read `docs/AVF_INSTALL_GUIDE.md` and `LLM.txt`. Source and tests are the protocol source of truth; this document does not replace them.

Current release baseline (2026-10-14): Apps `v0.9.7.1`, Android `0.9.7.1 (81)`, iOS `0.9.7 (81)`. For the Android 10–13 fix, installing Standalone is recommended. The compatible AVF Agent stays at `v0.4.6` (Debian `0.4.6-1`), and the Relay protocol stays at `0.2.1`. The GitHub IPA is an unsigned package meant for re-signing. The maintainer uploads TestFlight separately through Xcode; upload, processing, and review status must not be conflated. The maintainer AirSIM Relay is `https://airsim-push.remotepilot.site`. DJOneHub's `https://push.remotepilot.site` must not be used for AirSIM. Old version numbers in historical Release documents are archival facts and must not be mechanically replaced.

Changes in this version: the local pairing switch on iOS “Pair Android phone” controls only the current configuration package and does not write the global mode. Agent auto-registration must protect that local configuration, and pairing must be serialized with in-flight Agent writes. The Android API 29+ compatibility branch is described in the shared README. Legacy AVF recovery below API 34 uses a tappable notification and does not call the newer ActivityOptions methods. Cloud hang-up generation isolation and PCM jitter improvements are in `docs/cloud-pcm-resilience.md`. Users have reported that, on devices this round, the hang-up UI no longer reproduces and audio is more stable. That does not constitute acceptance across all device models, weak networks, or Watch.

## 1. Project goals

AirSIM uses an Android phone as the cellular phone and SMS endpoint:

- The recommended Android Standalone APK talks to Android Telecom, SMS, and the Shizuku audio bridge, and runs a built-in Agent in a foreground service.
- The built-in Agent maintains device state, command orchestration, Relay sessions, and media state. It does not use AVF, Terminal, Debian, `8575/8576`, or `airsim-installerd`.
- The older Android AVF Agent and `airsim-installerd` are only for compatibility and fallback.
- iPhone and Apple Watch use calling and SMS over VoWLAN or Cloudflare Relay.
- Cloudflare Relay handles public-network events, APNs, the command queue, the Dashboard, and media relay.

Do not describe AirSIM as a soft SIM, a carrier replacement, or an emergency-call service. Do not restore historical brands, historical hardware-module designs, or descriptions that disagree with the current Samsung Android architecture.

AirSIM uses `PolyForm-Noncommercial-1.0.0`. It is a source-available project, not OSI open-source software. Assist only with personal study, research, experimentation, and the other noncommercial uses named in the license. Commercial use, paid services, commercial-product integration, and expected commercial applications require a separate written authorization from the copyright holder. Modifications and distribution must keep `LICENSE`, `NOTICE`, and third-party notices.

## 2. Component map and sources of truth

| Scope | Read first | Core entry | Verification command |
| --- | --- | --- | --- |
| Android Standalone | `android-standalone/README.md` | `android-standalone/`, `android/phone-control-app/src/` | `./android-standalone/test.sh` |
| Samsung control app | `android/phone-control-app/README.md` | `android/phone-control-app/src/`, `build.sh` | `./android/phone-control-app/test.sh` |
| Samsung audio bridge | `android/phone-audio-bridge/README.md` | `android/phone-audio-bridge/src/`, `run-device-bridge.sh` | `./android/phone-audio-bridge/build.sh` |
| AVF Agent | `module/module-agent/README.md` | `module/module-agent/main.go`, `router.go` | `(cd module/module-agent && go test ./...)` |
| AVF Installer | `module/packaging/README.md` | `module/avf-installerd/` | `(cd module/avf-installerd && go test ./...)` |
| Debian release | `module/packaging/README.md` | `module/packaging/build-avf-deb.sh` | `./module/packaging/test.sh` |
| iOS / watchOS | `iOS/README.md` | `iOS/AirSIM.xcodeproj`, `iOS/AirSIM/` | `xcodebuild ... build-for-testing` |
| Cloudflare Relay | `push-relay-worker/README.md` | `push-relay-worker/src/index.mjs` | `(cd push-relay-worker && npm test && npm run check)` |
| Protocol | `docs/` | VoWLAN and Samsung hotspot pairing docs | Cross-check both implementations and tests |

When changing a cross-component protocol, search every producer, consumer, model, persisted field, test, and document. Do not change only one side.

## 3. Architecture contracts that must not be broken

1. The Android side targets Samsung Android and the system phone capability. Emergency calls are handed back to the system phone app.
2. AVF Linux publishes only one `airsim-avf-agent_<version>-<release>_arm64.deb`. Hardware differences are handled by the Android app's capability detection and adaptation layer.
3. The main Agent does not update itself. The Android app calls the independent `airsim-installerd` for checks, installs, repairs, and rollbacks.
4. The installer accepts only Debian packages named `airsim-avf-agent`, architecture `arm64`, with a valid Ed25519 signature. It cannot run an arbitrary shell.
5. AVF control and PCM services listen only on an internal private network or loopback. They must not be exposed on general Wi-Fi, a hotspot, cellular, or a public interface.
6. The VoWLAN control plane must enforce the route allowlist, timestamps, nonces, HMAC, and message-size checks.
7. The call chooses VoWLAN or Relay transport when it is set up. The path must not switch silently before that call ends.
8. PCM is handled only in memory and on the network. Only an iPhone call recording the user explicitly turns on may be written to a protected local file excluded from backup. Do not upload recordings or write PCM into diagnostic logs.
9. `com.example.airsim` in the iOS/watchOS project is a placeholder. The deployer must use their own Apple Team, unique Bundle ID, certificates, and provisioning profile.
10. Relay `ALLOWED_BUNDLE_ID` must equal the main iOS app Bundle ID after re-signing.
11. AirSIM and DJOneHub must use different hostnames, Workers, KV, Durable Objects, and Dashboard tokens. The maintainer AirSIM hostname is `airsim-push.remotepilot.site`. `push.remotepilot.site` belongs to DJOneHub and must not be taken over by AirSIM.

## 4. Security and Secret rules

The following must never be committed, written to logs, or placed as plaintext values in example configuration:

- Apple APNs `.p8` private keys and `APNS_P8`
- `DASHBOARD_TOKEN`
- Cloudflare API tokens
- Agent bearer tokens, device Secrets, pairing keys, and HMAC material
- The AVF Debian release private key
- The Android keystore, Apple signing identities, and provisioning profiles
- Real phone numbers, full SMS bodies, Push tokens, and PCM data

Relay `APNS_P8` and `DASHBOARD_TOKEN` are required Cloudflare Worker Secrets. `wrangler.example.toml` may declare names only. Production values come from `wrangler secret put`, the versions secret flow, or a CI Secret Store. Do not put Secrets in `[vars]`.

Before any deployment operation, check:

```sh
git status --short
git diff --check
git grep -nE 'BEGIN (EC |)PRIVATE KEY|APNS_P8[[:space:]]*=|DASHBOARD_TOKEN[[:space:]]*=' -- ':!push-relay-worker/README.md' ':!push-relay-worker/wrangler.example.toml'
```

Placeholder text in example commands is not a real Secret. If a scan hits, judge each hit individually and do not echo sensitive values in the reply.

## 5. Recommended work order

1. Read the root README, the target component README, the source, and the existing tests.
2. Check `git status --short` and keep the user's existing changes. Do not reset, overwrite, or clean unrelated files.
3. Use `rg` to locate protocol fields, environment variables, Bundle IDs, ports, and every consumer.
4. Change the smallest necessary range first, then update tests and docs.
5. Run the target component's verification first, then widen verification according to cross-component impact.
6. When the change involves install flow, ports, versions, or recovery, update the related component READMEs, `docs/AVF_INSTALL_GUIDE.md`, `LLM.txt`, `codex.md`, and `claude.md`. Do not change only app copy or only one side of a script.
7. Before deployment, check Secrets, placeholders, Bundle IDs, Cloudflare resources, and the target environment.
8. The final report lists changed files, verification results, on-device or production steps not run, and remaining risk.

Do not run a Cloudflare production deploy, an Apple release, a GitHub Release, a real-device install, a remote push, or a Git push unless the user explicitly asks. Even when the user asks for a deployment, use only the account, device, domain, and signing identity they explicitly name. Do not guess.

## 6. Build and verification

### Android

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
```

APK paths follow the component README and the build script output. Real-call acceptance also requires checking the default phone role, Shizuku, the AVF private network, dial, answer, hang-up, SMS, bidirectional audio, and reboot recovery.

### AVF Agent, installer, and Debian package

```sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
```

A release build needs the Ed25519 private key stored outside the repository and the matching public key. A build without the private key is only a development artifact. It cannot be described as having passed production installerd signature verification.

v0.4.5 enables a new release public key. The old v0.4.4 private key was not retained. A device that has `0.4.4-1` installed cannot upgrade directly through the old installerd. Follow `docs/AVF_INSTALL_GUIDE.md` and run the one-time `rotate-avf-key.sh` in the AVF Terminal, verify the signature, keep the old package, and run the health check. The new private key is stored only outside the repository and is backed up as the GitHub Actions Secret `AIRSIM_RELEASE_PRIVATE_KEY_PEM`. Release packages must be signed with the local restricted private key or by authorized CI. Do not export the private key from the Secret. Do not pair an old signature with a new package or skip signature verification.

### iOS / watchOS

```sh
xcodebuild -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

A simulator build cannot verify the PushKit or CallKit on-device lifecycle, APNs, Watch companion install, cellular calling, or call audio. Before installing on a device, replace the full set of Bundle ID, Team, capabilities, entitlements, and provisioning profile.

### Cloudflare Relay

Maintainer production facts (as of 2026-10-08): the Worker name is `airsim-push-relay`, the hostname is `https://airsim-push.remotepilot.site`, and it allows only `com.eric3u.airsim`. It is fully isolated from the DJOneHub Worker at `https://push.remotepilot.site`. It is not a public Relay for arbitrary re-signed Bundle IDs. Both `/healthz` endpoints have been verified, as have AirSIM Dashboard anonymous `401` and correct-credential `200`. The AirSIM environment currently has no device registrations, so real APNs, Agent heartbeats, or cloud PCM cannot be claimed as accepted.

```sh
cd push-relay-worker
npm ci
npm test
npm run check
npx wrangler deploy --dry-run --config wrangler.toml
```

`wrangler.toml` is local/production configuration and is ignored. Create it from `wrangler.example.toml`. Before a production deploy, confirm the KV ID, Durable Object migrations, `ALLOWED_BUNDLE_ID`, APNs Team/Key ID, custom domain, and the two required Secrets.

## 7. Deployment checklist

### Samsung Android and AVF

- The AirSIM APK is built, signed, and installed.
- AirSIM is set as the default phone app. Shizuku is running and authorized.
- AVF Linux is started. The source and signing public key of the first-install script have been checked.
- The Android app has saved the correct AVF private-network address and control token.
- `airsim-agent` and `airsim-installerd` pass device-side checks on 8575 and 8576 respectively, and Agent `/api/health` shows `product=airsim`. Existing DJOneHub may stay on 7575. Older AirSIM Releases still occupy 7575. Until a port-migration release is published, do not run the old online install command on a coexistence device. A successful Agent health check does not replace installerd, control-token, and real-call acceptance. The AVF subnet changes dynamically.
- `cannot create runner / VM is not in stopped state` is an Android Terminal startup-state problem. Do not clear Linux data for it, and do not treat it as a Debian install failure. Follow `docs/AVF_INSTALL_GUIDE.md` for non-destructive troubleshooting.
- The app's “one-tap install” entry only copies the command. It does not execute it automatically inside AVF Debian. If Agent `8575` is online and installerd `8576` is offline, follow the guide and restore the existing service first. A fixed bootstrap script can reuse a retained `current.deb`. An old Release may still refuse a repeated install. Do not delete the rollback package to bypass the check. Without explicit release authorization, do not describe a source-tree fix as already in effect online.
- If Debian reports a `udev` / `libudev1` version mismatch, first look at `apt-cache policy udev libudev1` and `sudo apt-get -s -f install`. The AirSIM package has no direct `libudev1` dependency. The bootstrap script should run `apt-get check` first and stop. It does not automatically repair system packages, remove components, or downgrade.
- Agent, installerd, and the audio bridge are healthy. External networks cannot reach the internal ports.
- Dial, answer, reject, hang-up, DTMF, SMS, bidirectional PCM, and reboot recovery have been verified.

### iPhone and Apple Watch

- Bundle ID relationships among the main app, Watch App, Live Activity, and test target are correct.
- Team, certificates, provisioning profile, capabilities, and the final signed entitlements are correct.
- Relay `ALLOWED_BUNDLE_ID` matches the main app exactly.
- Sandbox and production tokens are not mixed.
- VoWLAN pairing, CallKit, PushKit, Watch, Live Activity, and media have been verified on device.

### Relay

- Use the deployer's own Cloudflare account, KV, Durable Objects, and domain.
- The AirSIM hostname must not reuse or overwrite DJOneHub's `push.remotepilot.site`. The maintainer deployment uses `airsim-push.remotepilot.site`.
- `APNS_P8` and `DASHBOARD_TOKEN` exist only in the Secret Store.
- Tests, syntax checks, and the dry-run pass.
- `/healthz`, Dashboard authentication, device registration, Agent heartbeats, APNs, and WebSocket have been verified.
- After release, use `wrangler tail` to watch errors, but logs must not show sensitive content.

## 8. Done criteria

“Build passed” means only that the local compile or tests succeeded. “Deployment complete” requires a deployment result from the target environment. “Works on device” requires evidence from an actual Samsung Android phone, iPhone/Apple Watch, AVF, and the network path. A step that was not run must not be written as complete.
