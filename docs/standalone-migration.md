# Standalone-only Android runtime

The AVF Go Agent, Debian installer, bootstrap scripts, Linux recovery UI and private-network backend have been retired from this source tree. Android Standalone is the only supported runtime. The shared Android build script and the Standalone wrapper use the same Standalone manifest.

## Preserve existing data

- Keep package `com.airsim.phonecontrol.pixel8pro` and the existing signing certificate when upgrading an existing Standalone installation. A distributed update also needs an appropriate increasing version code. Do not uninstall or clear app data to update.
- This cleanup retains the existing preference files: `standalone_agent` (registration and device credentials), `vowlan_pairing` (local pairing secret), `standalone_sms` (pending delivery and deduplication), and `control` (mode and diagnostics preferences). Android agent identity and Apple Keychain/history/recordings remain unchanged.
- The app reads existing registrations and SMS records in place. Local acknowledgement must not discard SMS still waiting for cloud delivery. The persistent-store regression suite exercises reopening pre-upgrade records, local/cloud acknowledgement and duplicate delivery.
- No source-tree operation stops or purges a service on a device. Existing AVF files under `/var/lib/airsim`, `/var/lib/airsim-installerd`, and `/etc/airsim` remain untouched. Retired endpoint/token preferences are left inert rather than erased.
- There is no automatic AVF-to-Standalone credential or SMS import. Existing AVF installations must retain their data, finish pending SMS delivery, and explicitly pair Standalone before decommissioning the old service. Do not purge Linux data or assume the optional Android inbox fallback imports old messages; it intentionally starts at the current inbox position.
- Old `agent_kind: avf` records remain readable by Apple clients and Relay. They are historical paired-device records, not an available runtime. The UI labels them as retired; current calls still require a fresh native-media heartbeat. Do not delete cloud registrations or change device IDs as part of this source cleanup.

## Current paths

`./android-standalone/build.sh` builds the Standalone APK. `./android/phone-control-app/build.sh` uses the same manifest and package by default; it retains its own output directory. The wrapper is the recommended entry point.

Pairing and call/SMS APIs keep their wire format. `AgentClient` forwards to `StandaloneAgentGateway` in process. Boot, Telecom and SMS receivers start `StandaloneAgentService` directly. Shizuku remains necessary for privileged native WebRTC audio; Linux Terminal and ports 8575/8576 are unused.

The historical `android/phone-audio-bridge` source and build scripts are removed. [Carrier-route evidence](carrier-route-validation.md) remains a physical acceptance gate. Package-scoped stale-process detection and network-interface exclusions are retained for upgrade safety.

## Validation

Run `./android-standalone/test.sh`, the default shared build and APK verification, and `npm test && npm run check` in `push-relay-worker`. Set `ANDROID_SDK_ROOT` to the installed SDK if needed. Build/test the Apple app after related UI changes.

Q25 and Pixel native carrier audio, background operation, repeated calls and Shizuku restart still require physical acceptance. Passing builds and JVM tests do not establish call quality or a release/deployment.

## Apple transport cleanup

iPhone local control uses authenticated Wi-Fi VoWLAN only. An unpaired/offline API has no URL and fails before starting a network request. The USB/QDC507 route and interface discovery have been removed. Live Activity buttons open the existing typed app link; the app rejects a mismatched call ID before calling answer, reject or hang-up. Old Live Activity transport strings decode as unavailable, preserving the rest of the payload. Existing pairing records, SMS history and recordings are unchanged.

Unused API wrappers and no-op PCM helpers are removed. WebRTC remains the only network-audio carrier; internal carrier samples and recording buffers remain. Legacy transport values still fail validation, and the older-Agent SMS polling fallback remains available.
