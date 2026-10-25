# AirSIM Android Standalone

> Current branch migration: native WebRTC and carrier capture/injection share the privileged Android process. There is no supported PCM network/IPC fallback. AVF voice is upgrade-required; Watch is an iPhone audio companion. Legacy bridge source/build instructions below are historical reference, not the current APK workflow. Physical-route and privileged-security gates remain unverified. See [the migration contract](../docs/webrtc-only-migration.md).


AirSIM Android Standalone is designed for compatible Android phones across device models. This fork is verified on Zinwa Q25 and Pixel 8 Pro; other hardware and feature/OS combinations require validation. See [Android compatibility and verification](../README.md#android-compatibility-and-verification) for requirements and scope.

AirSIM Android Standalone is the recommended Android deployment. It moves the Agent previously hosted in Android AVF Linux into an Android foreground service, providing a single APK. After installation, Linux Terminal, Debian, the AVF private network, and `airsim-installerd` are no longer required, and Agent/installer ports `8575` and `8576` are not used.

**[Android 10–13 hotfix 0.9.7.1 (81), recommended](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1)**. Official builds retain the original certificate and package name, allowing an in-place upgrade without data loss; do not uninstall first. Debug/re-signed builds with other certificates cannot replace them directly. This version does not update the Linux AVF Agent or Relay; iOS build 81 is uploaded separately through Xcode to TestFlight.

The following reports describe upstream release testing, separate from this fork’s verified hardware. This hotfix addresses missing Java I/O and array-conversion methods on older systems; it does not establish full Android 10–13/OEM audio compatibility. Redmi Android 12 received an in-place update preserving data, and the user confirmed VoBLE pairing and reported no call-UI recurrence with steadier cloud-call audio in that test round. The vivo Android 11 report was diagnosed but not retested; Android 10, 13, and realme have not been device-tested. See the [release notes](../docs/releases/0.9.7.1-android10-13.md) for scope, signing, and validation boundaries.

Standalone reuses Telecom, SMS, VoWLAN, pairing, and Shizuku management from [`android/phone-control-app`](../android/phone-control-app/README.md), and the call PCM bridge from [`android/phone-audio-bridge`](../android/phone-audio-bridge/README.md). This fork’s current Manifest uses package `com.airsim.phonecontrol.pixel8pro` and label “AirSIM Pixel 8 Pro”; these are build identity and branding, not a runtime model restriction. The distinct package can coexist with the legacy AVF app. Only one app can hold the default phone role and Shizuku PCM session at a time.

## Built-in capabilities

- Relay device registration, 30-second heartbeats, WebSocket cloud commands, and HTTP fallback fetching;
- Android Telecom dialing, answer, reject, hang-up, DTMF, and system SMS sending;
- Incoming-call push, call lifecycle, and single-stream cloud PCM media orchestration;
- Cloud and VoWLAN call audio use native WebRTC. NetEq holds at most 50 packets and fast-accelerates excess delay. The telephony loopback drops PCM older than 80 ms and does not add a second jitter buffer. See [WebRTC calls](../docs/webrtc.md);
- Local VoWLAN control and PCM links;
- Local VoBLE control and encrypted G.711 μ-law bidirectional audio;
- An in-process compatibility layer for the original Agent `/api/health`, `/api/android/status`, call, and audio-configuration APIs;
- Xiaomi HyperOS default phone-role guidance, with authorized Shizuku configuration when the system role-selection UI is unavailable;
- Non-Samsung devices select call uplink/downlink through Android `TYPE_TELEPHONY` audio devices; Samsung devices retain their voice TX route.
- A separate lock-screen call UI and answer/reject notification actions when acting as default phone app. During calls, the notification reopens the UI for hang-up. Android retains silent-forwarding behavior; showing the UI does not automatically switch audio back to the local earpiece.

VoWLAN `/api/calls/answer`, `/api/calls/reject`, and `/api/calls/hangup` accept optional JSON `call_id`, taken from the current call's `id` in `/api/calls/status`. With an ID, only that call may be affected. Expired or mismatched IDs are rejected without selecting another call. Older clients without an ID retain the current-call compatibility path.

## Runtime architecture

```text
iPhone / Apple Watch
        │  VoWLAN, VoBLE, or Cloudflare Relay
        ▼
AirSIM Android Standalone APK
        ├─ Built-in Agent: identity, heartbeats, commands, and media orchestration
        ├─ Telecom / SMS: cellular calls and text messages
        └─ Shizuku UserService: call PCM bridge
```

Shizuku remains the permission bridge for capturing and injecting system call audio. Standalone cannot bypass Android/OEM security boundaries or replace system emergency calling.

After startup system-permission requests finish, the app checks Shizuku. If absent, it shows the official download URL (`https://shizuku.rikka.app/zh-hans/download/`) and “Download Shizuku”; if installed but stopped, “Open Shizuku”; if running but unauthorized, “Authorize.” No prompt appears when ready. It prompts at most once per launch and does not repeat when returning from the download page or Shizuku. “Later” continues into the app, but an unready call audio bridge cannot work. The app never silently installs Shizuku or bypasses system authorization.

## Build and test

Compatibility fixes also remove `StringBuilder.isEmpty()`, URL encoding/decoding `Charset` overloads, and `InputStream.nullInputStream()`. Android 10/11 uses the older SMS factory while preserving the selected SMS SIM, with fallback for a null service. Shizuku mute uses shell-identity `AudioManager` capability detection, readback, and original-state restoration instead of possibly absent OEM `cmd audio`. A system refusal to mute is an explicit failure. Mute support and JVM tests do not establish real bidirectional-call acceptance.

Shared tests and APK builds check Android 11/12 Java API compatibility, preventing log reading, permission lists, VoWLAN, and Relay paths from referencing unavailable stream-reading and array-conversion overloads. These targeted checks do not replace real-device startup and call acceptance on different Android versions.

Requires JDK 17, Android SDK Platform 35, Build Tools 35, and Python 3. The build reads `ANDROID_SDK_ROOT`, falling back to the Homebrew Android command-line tools path if unset.

```sh
./android-standalone/test.sh
./android-standalone/build.sh
```

Debug-signed APK output (the app itself is non-debuggable to protect its private registration data):

```text
android-standalone/build/android/AirSIM-Android-Standalone-debug.apk
```

Build a non-debuggable, release-signed APK:

```sh
AIRSIM_ANDROID_BUILD_VARIANT=release \
AIRSIM_ANDROID_KEYSTORE=/absolute/path/to/airsim-android-release.jks \
AIRSIM_ANDROID_KEY_ALIAS=airsim \
AIRSIM_ANDROID_KEYSTORE_PASSWORD='injected from Secret Store' \
AIRSIM_ANDROID_KEY_PASSWORD='injected from Secret Store' \
./android-standalone/build.sh
```

Release output is `android-standalone/build/android/AirSIM-Android-Standalone-release.apk`. Do not put signing private keys or passwords in the repository, scripts, Releases, or logs. In-place upgrades must retain the prior signing certificate.

## Installation and initial setup

1. Install the APK and start Shizuku. Wireless debugging usually requires restarting Shizuku after a reboot.
2. Open AirSIM Standalone, grant phone, SMS, and notification permissions, and follow the default-phone-app prompt. Optional “Read SMS” permission provides inbox fallback: initial authorization records the current inbox position and scans only new messages afterward. If denied, SMS broadcasts remain available. Android restricted-permission policy may prevent some installation sources from granting it.
   “Read phone state/number” permission lets the iPhone paired-Agent list display the SIM number. If the carrier has not stored a number or permission is denied, iPhone shows “Number not provided.” Selecting a default calling SIM requires phone-state permission.
3. If Xiaomi HyperOS does not open default-phone selection, authorize AirSIM in Shizuku first and let the app configure the system role automatically. No manual ADB command is needed.
4. Enter your Relay URL, device identifier, and pairing details on Android. If using your own Apple Bundle ID, Relay `ALLOWED_BUNDLE_ID` and APNs topics must match.
5. First validate VoWLAN with iPhone and Android on the same hotspot/LAN, then validate remote Relay mode.

### Call history on iPhone

Grant Android AirSIM the optional call-log permission to show system call history in the iPhone app's **Recents** tab, including calls made before an app restart. Recents refreshes when opened, when the app returns to the foreground, and shortly after a cloud call ends. Pull down or use the refresh button to retry. History queries wait until the current call ends.

VoWLAN and Cloud mode retrieve the same latest 100 Android records. iPhone retains up to 500 records locally, so existing history stays visible while Android is offline. Deleting a row hides it on that iPhone and keeps it hidden after later refreshes; it does not delete Android's system call log. Denying call-log access does not prevent calls, but remote history reports a permission error.

### Default calling SIM (dual/multi-SIM)

Under Android AirSIM “Settings → Default Calling SIM,” select “Follow System Default” or an enabled SIM/eSIM. Slots and carriers come from the system; a number is shown only when permission and carrier data are available. The local preference survives restart and in-place upgrades. BLE, VoWLAN, Relay, and Android local dialing all use it, without network access for SIM selection.

AirSIM selects the SIM through Telecom `EXTRA_PHONE_ACCOUNT_HANDLE`, without changing system call or SMS defaults. It rechecks the account on each dial. If the selected SIM is disabled/removed or phone-state permission is revoked, it returns an explicit error without choosing another SIM. System safety routing still determines emergency calls and may override this choice.

### Configure VoBLE Bluetooth mode

Authenticated `device_info`, VoWLAN health checks, and Standalone Relay heartbeats read the device name and number live. The number follows the current calling SIM; changing/disabling a SIM or losing number access never substitutes the initial pairing's old number. Newer iPhone settings can delete one device's local pairing record. Online Bluetooth deletion attempts to revoke both ends' credentials; after offline deletion, clear remaining Android credentials under “VoBLE Authentication” before re-pairing if needed.

VoBLE is an independent settings mode. It does not require prior VoWLAN pairing or change existing VoWLAN/Relay configuration:

1. Keep AirSIM Standalone as Android's default phone app, grant nearby-device/Bluetooth and notification permissions, and confirm the Shizuku PCM bridge is running.
2. Enable VoBLE on Android's status screen. Select “Direct Bluetooth” in iPhone AirSIM settings, scan, and choose the Android device.
3. Compare the short code on both devices and confirm pairing. Long-term keys remain only in Android Keystore and iOS Keychain; do not screenshot, record, or log them.
4. Make one outgoing and one incoming call. Check answer, reject, hang-up, mute, speaker, and DTMF, then verify bidirectional audio.

Bluetooth mode transports control and G.711 μ-law 8 kHz mono audio over BLE GATT, with AES-256-GCM authenticated frames. It uses no Relay, PushKit, or cloud-registration parameters and provides no Bluetooth PAN internet sharing; configure iPhone internet separately. The Android PCM bridge, default phone role, and system Telecom remain required. A brief disconnection may resume only the same `call_id`/generation within three seconds; a longer gap ends the media session to prevent old packets entering a later call.

When dialing over VoBLE, the provisional iPhone `call_id` and the later authoritative Android Telecom `call_id` share one generation. Android replaces the ID without advancing generation, preventing media start, DTMF, and hang-up from being mistaken for a previous call's `call_mismatch`.

“VoBLE Authentication” in settings shows Bluetooth permission, credential, and session state. Normal unpairing begins on iPhone through the authenticated control channel and deletes both ends' credentials. If reinstalling one end causes `already paired`, `peer is not paired`, or reconnection authentication failures, clear Android's old credentials here, clear iPhone's local credentials, and compare the new six-digit security code. This does not change VoWLAN or Relay configuration.

iOS does not guarantee background BLE incoming-call wake-up after the user force-quits the app; reopening AirSIM resumes scanning. Apple Watch mirrors incoming calls/control through iPhone CallKit/WatchConnectivity rather than connecting to Android BLE directly. Whether audio can route to Watch depends on iPhone/watchOS system routing.

Lock-screen incoming calls use a dedicated high-priority “AirSIM Incoming Calls” notification channel. On Android 14+, if system settings deny full-screen call permission, only an actionable banner may appear. The system/user controls that permission; the app cannot bypass it. Test locked-screen answer, reject, hang-up, and iPhone audio routing on each target device.

### Crash reports

Standalone and AVF Bridge save the most recent unhandled Java exception stack to app-private storage. Reports include app version, Android SDK, model, thread, and stack, with phone numbers, tokens, passwords, and pairing codes redacted before saving/sharing. Only one report is retained, limited to 48 KiB.

On the next launch, “Previous crash detected” allows sending, opening the Debug sharing entry point, or deferring. “Send Crash Report” opens Android's share sheet with up to 12 KiB of recent redacted Debug logs. Nothing uploads automatically. The Debug screen can delete the report permanently.

Wireless-debugging installation example:

```sh
adb connect DEVICE_IP:WIRELESS_ADB_PORT
adb install -r android-standalone/build/android/AirSIM-Android-Standalone-debug.apk
```

Wireless debugging addresses and ports can change at each pairing; example values are not fixed device configuration.

## Migrate from the AVF version

- Standalone has a separate package name and does not automatically read the legacy app's local data. Record your Relay, device ID, and pairing details before migration.
- After installing and validating Standalone, make it the default phone app. Do not allow two AirSIM packages to control the same call.
- Once Standalone works, the AVF Agent can be stopped. Deleting Debian/AVF data is a separate destructive operation, not part of APK installation.
- To revert, make the old app the default phone app again and restore its AVF Agent. Both versions may remain installed for fallback.

## Device acceptance

- The screen shows healthy built-in Agent, Relay, and VoWLAN status without depending on `8575/8576`;
- The foreground service recovers after Android restart, with clear feedback if Shizuku becomes unavailable;
- iPhone can dial, answer, reject, hang up, and send DTMF;
- Android/iPhone bidirectional audio uses the expected device and does not revert to the Xiaomi earpiece;
- SMS send results follow Android system receipts, and the recipient confirms actual delivery;
- Same-network VoWLAN and separate-network Relay are tested independently, with no transport change mid-call.
- Select VoBLE, turn off Wi-Fi, and confirm outgoing/incoming calls and bidirectional audio do not access Relay. Then verify same-call recovery within three seconds and termination after timeout.

Project-wide results, disconnected devices, and failures are recorded in the [VoBLE device test matrix](../docs/voble-real-device-test-matrix.md).

## Security boundaries

- Call PCM is processed only in memory and on the network, never saved to disk;
- Logs must not contain complete SMS messages, phone numbers, push tokens, pairing keys, or Relay secrets;
- The APK contains no APNs private keys, Cloudflare tokens, Android release private keys, or Apple signing identities;
- Use is limited to noncommercial purposes allowed by the [PolyForm Noncommercial License 1.0.0](../LICENSE).

### Native WebRTC cloud audio

The standalone Agent reports only native WebRTC, with capability revision 2 and
fresh service readiness. Watch controls iPhone audio; AVF and old unsupported
clients fail clearly without a fallback. The authenticated WebSocket carries
SDP/ICE and call lifecycle only. The app fetches ephemeral ICE credentials and
passes those, never the account secret, to the privileged peer.

Android keeps pinned WebRTC SDK `144.7559.15`. Native WebRTC and the 8 kHz carrier
audio device share the Shizuku process. Local samples remain in bounded 10 ms
buffers; no TCP bridge or audio IPC is used. Opus/NetEq owns jitter and loss
concealment. Current route verification requires a visible telephony sink, so
hidden Samsung VOICE_TX routes need a separately verified capability adapter.
Neither Q25 nor Pixel 8 Pro has yet accepted this new architecture on hardware.
See the [draft migration gate](../docs/webrtc-only-migration.md).

Builds verify the AAR SHA-256, package all four supplied ABIs, align shared
libraries to 16 KB, and include dependency notices as APK assets. See
`android/phone-control-app/third_party/webrtc/README.md` for the pinned native
contract and license provenance. Updating this SDK requires rechecking its JNI
signatures and exercising native tests.

Run the regular `test.sh` with `ANDROID_SDK_ROOT` pointing to the installed SDK.
After building, use a dedicated running emulator for native tests:

```sh
AIRSIM_TEST_SERIAL=emulator-5588 ../android/phone-control-app/test-native.sh
```

The native test creates two actual peers, sends distinct synthetic 400/1000 Hz
PCM tones, checks decoded audio in both directions, checks Opus/DTLS/RTP stats,
and verifies audio threads stop on disposal. To test forced TURN, additionally
set `AIRSIM_TEST_TURN_CONFIG` to a private JSON file containing `android_url`,
`username`, and `credential`. The script copies it to private app storage and
removes it after the run; never commit or log that file. The test refuses a
physical-device serial. These tests do not exercise a cellular call, the rooted
Q25 audio route, iPhone audio routing, or production NAT traversal.
