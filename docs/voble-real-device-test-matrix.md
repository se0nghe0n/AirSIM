# VoBLE Device Test Matrix

This document records reproducible validation evidence for the `VoBLE` branch. Status applies only to explicitly exercised items; disconnected devices and calls that did not take place are never marked passed.

## Validation baseline

- Date: 2026-10-13 (Asia/Shanghai)
- Baseline commit: `45ef904`; the documentation revision is this document's final commit
- Xcode：27.0（27A266a）
- iPhone Air: iPhone18,4, iOS 27.0 (24A437), Developer Mode enabled, paired over the LAN
- Android: `adb devices -l` was empty in this round; neither Samsung nor Xiaomi was connected
- Apple Watch: both known devices reported unavailable
- Privacy: records contain no phone numbers, SMS content, pairing keys, nonces, authentication tags, push tokens, or PCM

## Automation and builds

| Scope | Command | Result | Artifact or notes |
| --- | --- | --- | --- |
| Android Bridge JVM | `./android/phone-control-app/test.sh` | Passed | Core, NotificationUpdateGate, and call repository passed; includes VoBLE protocol, authentication, and PCM queues |
| Android Standalone integration | `./android-standalone/test.sh` | Passed | `BridgeUnitTests checks=47`, followed by Standalone Bridge build/signature checks |
| Android AVF Bridge APK | `./android/phone-control-app/build.sh` | Passed | `android/phone-control-app/build/android/AirSIM-Phone-Bridge-debug.apk`; APK v3 signature verified |
| Android Standalone APK | `./android-standalone/build.sh` | Passed | `android-standalone/build/android/AirSIM-Android-Standalone-debug.apk`; APK v3 signature verified |
| iOS test compilation | `xcodebuild build-for-testing ... generic/platform=iOS Simulator CODE_SIGNING_ALLOWED=NO` | Passed | App and XCTest bundle compiled |
| iOS runtime XCTest | `xcodebuild test ... iPhone Air,OS=27.0` | No complete final result | New lifecycle cases passed while running, then CoreSimulator runner disappeared/restarted; this is not a full-suite pass. The earlier Task 6 baseline completed 58 tests |
| iPhoneOS unsigned build | `xcodebuild build ... generic/platform=iOS CODE_SIGNING_ALLOWED=NO` | Passed | arm64 app, Live Activity, and Watch targets compiled; input for local re-signing, not official signing acceptance |

## Device installation and feature matrix

| Device/scenario | Status | Evidence or blocker |
| --- | --- | --- |
| iPhone Air in-place install (data preserved) | Passed | Re-signed with a development profile over `AirSIM Diag`; `devicectl` install/launch succeeded; main and Live Activity processes stayed alive; app data was not cleared |
| Samsung Standalone in-place install | Blocked | No devices in `adb devices -l`; no install or real call executed |
| Samsung AVF Bridge + AVF PCM | Blocked | Samsung disconnected; next-session resolution after AVF address changes not tested |
| Xiaomi HyperOS Standalone | Blocked | Xiaomi disconnected |
| Apple Watch mirrored incoming call/ringtone stop | Blocked | Watch unavailable |
| VoBLE outgoing/incoming calls with Wi-Fi off | Not run | Requires both Android and iPhone online and a real carrier call |
| First audio in both directions, mute, speaker, DTMF | Not run | Same prerequisite |
| Same-generation recovery within three seconds | Automation passed; device test not run | Reducer/coordinator coverage; still needs a real BLE radio environment |
| Termination after three seconds, wrong key, unpairing | Automation passed; device test not run | Still needs device UI and system-behavior acceptance |
| 30-minute queue/memory stability | Not run | Requires an ongoing real call; simulated results are not a substitute |

## Device acceptance steps

### Standalone

1. Install in place with `adb install -r android-standalone/build/android/AirSIM-Android-Standalone-debug.apk`; do not clear data.
2. Confirm default phone role, nearby-device and notification permissions, Shizuku, and PCM bridge readiness.
3. Select “Direct Bluetooth” on iPhone, compare the short code on both devices, and confirm.
4. Turn off Wi-Fi on both devices, keep Relay unavailable, and make outgoing and incoming calls.
5. Record dial response, answer-to-first-audio time, bidirectional audio, mute, speaker, DTMF, hang-up from Android and iPhone, and whether Watch stops ringing.
6. Briefly interrupt Bluetooth for less than three seconds during a call; only the same `call_id`/generation may recover. Then interrupt for more than three seconds; media, CallKit, and Live Activity should end and clean up.
7. Run for 30 minutes, monitoring the GATT send queue, drops, jitter, memory, and battery. Logs must contain no numbers or keys.

### AVF PCM

1. Install AVF Bridge in place and ensure it and Standalone do not both hold the default phone role.
2. Complete a bidirectional VoBLE call and record the AVF PCM endpoint.
3. End the call and restart AVF so the private address changes; the next call must resolve the new address.
4. Do not switch the endpoint during an active call; address changes apply only to the next media session.

### Xiaomi and failure scenarios

On HyperOS, check background restrictions, lock screen, wrong keys, unpairing, unavailable Relay, VPN on/off, Wi-Fi off, messaging after iOS force-quit, and revoked Bluetooth permissions. VoBLE must not refuse local pairing or dialing because Relay/PushKit tokens are unavailable.

## 2026-10-13 evening: Bluetooth audio reproduction and fixes

- Samsung SM-F766U connected over wireless ADB at `192.168.31.203:38137`, with Standalone foreground service healthy; iPhone Air used `AirSIM Diag` with data preserved.
- Before the fix, a real Bluetooth outgoing call reached Android Telecom `active`. PCM downlink kept increasing; uplink appeared only briefly as silent frames. This did not establish bidirectional voice success.
- Android `STREAM_VOICE_CALL` was muted and the audio HAL received `setVoiceVolume(0.0)` and `l_volume_voice=0.0`. App mute-request logs alone cannot establish listening behavior.
- The provisional iOS outgoing ID no longer binds the CallKit backend identity; synchronization waits for Android's authoritative ID. A dial response arriving after Telecom events no longer restores the provisional ID or downgrades an active call to connecting.
- BLE audio distinguishes CallKit activation from app activation. The latter enables `playAndRecord/voiceChat` after microphone permission, and rereads actual CallKit activation after the permission dialog returns.
- All 76 iOS XTests passed; iPhoneOS build succeeded. The fix was installed in place, with main and Live Activity processes alive. Debug logs added engine status and captured/played/dropped counts, without numbers, keys, or audio contents.
- Post-fix bidirectional listening quality, actual Samsung mute, real incoming calls, and lock-screen behavior still required device retesting and were not marked passed.

## 2026-10-13: severe interference after bidirectional audio

- The user confirmed audio on both ends during a real outgoing call, but severe interference prevented audio acceptance.
- iPhone logs showed continuous capture/playback engines. In about 36 seconds, 1820 frames were captured, 1650 scheduled, and 1639 dropped. Playback counts include concealed frames and do not prove receipt of valid speech.
- New regressions reproduced sequence advancement with an empty buffer, rejection of new audio when full, and repeated stale audio across a long gap. All three failed on the old implementation.
- Playback now replenishes from completion callbacks, scheduling at most 60 ms ahead. The timer only starts or resumes after gaps instead of serving as the 20 ms audio clock. Stop/new-call invalidates old completion callbacks.
- Empty buffers stop sequence advancement and rebuffer. Overflow retains the latest eight frames; longer gaps skip stale audio; replay detection is bounded. All 79 iOS XTests passed.
- Diagnostics separately record received, replayed, late, invalid, skipped, and concealed frames. Android logs actual AudioTrack device types. An available Samsung VOICE_TX label alone does not prove audio goes exclusively to cellular uplink.
- iPhoneOS compilation, re-sign verification, iPhone Air in-place install, and launch passed; main and Live Activity processes survived. Samsung Standalone in-place install passed; Shizuku user service and PCM bridge restarted as new processes listening on localhost.
- Android core, notifications, call repository, 47 PCM bridge checks, and Standalone tests passed. The first parallel build stopped because of temporary local disk exhaustion; a sequential rerun after the iPhone build passed, with existing SDK/JDK deprecation warnings.
- Listening quality, actual output routing, and Samsung local mute still required a real-call retest; unit tests were not a substitute.

## Subsequent stutter, status, and re-pairing tests

- The user confirmed Bluetooth audio on iPhone but with stuttering; the call screen still said the link was being established, and clearing pairing required toggling system Bluetooth.
- Samsung's actual AudioTrack device was TYPE_TELEPHONY (18), with Telephony Tx sink=true and increasing bidirectional PCM. iPhone accumulated 1901 received frames, no authentication errors, replay, or late drops, and 83 skipped playback frames.
- `dataPlayedBack` includes downstream Voice Processing I/O and output-device presentation latency. The bounded 60 ms streaming queue now replenishes on `dataConsumed`. A real AVAudioEngine offline-render regression showed the old callback could not replenish without device presentation, while the new callback fired after data consumption. Reference: [Apple callback documentation](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback).
- Call status now reads and subscribes to the Bluetooth audio engine for the locked transport, rather than using Wi-Fi engine/stale cloud state to represent BLE media.
- iOS waits for the old connection's cancellation callback before scanning or connecting again and ignores old-peripheral callbacks. Native automatic reconnection retains the target and rediscovers services. Android local credential clearing also closes the owner's GATT connection and releases old subscriptions.
- Three new iOS regressions failed on old behavior; all 82 tests passed after the change. Android's credential-revocation/closes-transport regression also failed first, then passed; Standalone build/tests passed. Real listening quality and re-pairing still needed device acceptance.
- Both ends received in-place installs with data preserved: Samsung through its updated wireless-debugging connection, and iPhone Air through `devicectl` after reconnecting. Neither apps nor pairing data were deleted. New logs resumed; the user still needed to check call smoothness and direct re-pairing after unpairing.

## “Not started” after unpairing

- Later user testing found “Not started” on the iPhone Bluetooth Agent screen. Device configuration remained bluetooth and Android logged unpairing; the user had not switched to another mode.
- iOS `unpairCurrentPeer` removed both credentials but only called `stop`. Since the screen did not reappear, `onAppear` did not restart scanning. Reset after unpair/clear now stops the old session and restarts scanning if previously enabled, while remaining disabled otherwise. Scanning still waits for old GATT disconnection, preserving the cancellation barrier.
- A new regression caught “disconnect without scan.” All 83 iOS tests and iPhoneOS compilation passed after the fix. DEBUG logs record enabled/state/waiting-for-cancellation flags, not keys, security codes, or numbers.
- After in-place installation, the device left stopped but remained connecting, without waiting on an old cancellation callback. Android GATT and connectable advertising were registered normally. Cached-peripheral connection had no timeout, so an eight-second watchdog was added. Only connecting timeout cancels the old connection; after cancellation, it skips cached restoration and scans again. It does not interrupt authenticating/ready and also covers native reconnection waits.
- The timeout-policy regression failed first then passed; all 84 iOS tests and the iPhoneOS build passed. Installed over AirSIM Diag with data preserved. Device logs still needed to confirm scanning and security-code authentication recovery; this was not audio-stutter or re-pairing acceptance.
- Further device evidence showed cancellation after connecting timeout without a disconnect callback, leaving the barrier blocked. Actual peripheral-state observation was added: release only when that same old peripheral is disconnected, never for connecting/connected/disconnecting or unrelated peripherals. Observe for at most eight seconds, then report an explicit error instead of forcing overlapping connections.
- The disconnected-state barrier regression failed first then passed; all 85 iOS tests, iPhoneOS compilation, and signing verification passed. The build was installed in place on iPhone Air again.
- Subsequent device logs reached connect_timeout → cancellation_finished → scanning → connecting → connected → authenticating without toggling system Bluetooth. First authentication failed; an in-app reset then scanned, connected, authenticated, and reached ready. Link/authentication recovery was verified, but not call listening quality.
- A later real Bluetooth call logged engineRunning=true, received=1703, played=1676, captured=1685, with replay/late/invalid/concealed all zero. skipped=23 and dropped=9 stopped increasing in the latter half; the media engine stopped normally at the end. There is device evidence for bidirectional data flow and cleanup; listening quality and the “Bluetooth voice connected” label still needed user confirmation.

## call_mismatch after Bluetooth-only hang-up

- The user confirmed normal Bluetooth calls but saw call_mismatch after hang-up with Wi-Fi and mobile data off on both ends. This is not evidence of unavailable VoWLAN/Relay and must not be masked by turning networking on.
- Android cleared call ownership on authoritative ended, causing later end/reject to be treated as call_mismatch. It now idempotently acknowledges a recorded terminal state for the same callID+generation, without invoking Telecom or affecting the next call. Unknown identities and unauthenticated commands remain rejected.
- iOS could receive ended while awaiting hang-up response, then emit ending or show a late error on the dialer. It now emits ending only while that identity remains current and accepts a late hang-up error as completed only if that identity already has an authenticated terminal event. Real current-call errors are not hidden.
- Android regressions cover ended-first, repeated end/reject, isolation from new calls, unknown IDs, and unauthenticated rejection; they failed on old code. iOS injected control transport into the real call coordinator, reproducing late-success restoration of ending and late-error alerts; both failed on old code. All 87 iOS tests and Android phone-control tests then passed. New DEBUG state/command logs omit numbers, call IDs, and keys.
- Standalone tests and APK build passed and installed over Flip7 preserving data. iPhoneOS compilation, signature checks, and AirSIM Diag in-place install on Air succeeded. Whether the pure-BLE hang-up alert disappeared still required a post-install device retest; regression tests were not actual acceptance.

## Android default calling SIM (dual/multi-SIM)

- Android settings gained “Default Calling SIM”: follow system default or explicitly select an enabled cellular SIM/eSIM. The preference is private local state, does not change system call/SMS defaults, and needs no Wi-Fi or Relay.
- VoBLE, Standalone VoWLAN/Relay, legacy AVF commands, and Android local dialing all use the selected `PhoneAccountHandle`. Accounts are rechecked before dialing; disabled/removed SIMs or revoked phone-state permission return explicit errors, without switching SIMs automatically.
- Eight JVM regressions first demonstrated missing selection support, then passed: system default, persistence, invalid SIM/revoked permission, disabled/VoIP-account filtering, shared dial path, optional number/metadata permissions, Android 29 compatibility, and three-SIM/list-order changes.
- Full Standalone tests/build and AVF Bridge APK build passed. In-place installation on Samsung Flip7 succeeded. It was locked, so SIM-selection UI, real dual-SIM dialing, and unchanged default SMS SIM still needed device testing; JVM Telecom-parameter checks were not carrier-routing acceptance.

## Paired-device cleanup and number refresh after SIM changes

- iPhone settings gained a device list below “Pair Samsung Phone,” with individual confirmed deletion. History stores ID, name, and Agent type, never cached numbers; offline history is not a dialable route.
- Deletion clears local history/bindings and corresponding BLE credentials. A device-level rejection marker blocks stale advertisements, cloud state, and late responses from restoring it. Online BLE attempts remote unpair; offline deletion does not claim Android/Relay authorization revocation. Other devices, calls, and SMS are unaffected.
- BLE now connects from current advertising rather than a cached UUID; authenticated `device_info` verifies identity. Empty numbers show unavailable without borrowing old VoWLAN/Relay numbers. Current VoWLAN health checks clear stale empty values, and late old-session results cannot update deleted devices or devices after discovery restarts.
- Standalone heartbeats no longer reuse the initially registered number. Current Android identity follows the app-selected or system-default calling SIM; disabled/changed SIMs and revoked permissions never borrow another SIM's number. Legacy AVF Linux Agent cloud heartbeats still use registration metadata and were not migrated.
- Five new iOS regressions reproduced stale numbers after empty values, non-persistent deletion, identity mismatch, reconnect from deleted-device advertising, and incomplete offline credential revocation. After fixes, the full **92-test suite passed**, as did iPhoneOS compilation and diagnostic-package signing checks. Offline-revocation tests retained the real BLE controller and replaced only credential storage. The unsigned Simulator lacked Keychain entitlement (-34018); in-memory tests were not claimed as real Keychain acceptance.
- Android current-SIM identity tests first failed because the first SIM was incorrectly selected, then phone-control, Standalone, and AVF Bridge builds passed. Builds installed with data preserved on Flip7 and iPhone Air's AirSIM Diag. iPhone was locked and system launch was rejected (Locked), so new-list display, real SIM changes, and delete/re-pair still awaited device acceptance; real device records were not deleted for testing.

### 2026-10-14 diagnostic-build launch-crash follow-up

- After unlocking, the user hit a launch crash. Air device `AirSIM-2026-10-14-010451.ips` showed DYLD termination before application code due to unsigned `AirSIM.debug.dylib`. The Live Activity crash likewise involved unsigned `AirSIMLiveActivityExtension.debug.dylib`, not device-list or history data.
- Separate `codesign --verify --strict` checks failed on both old Debug libraries, confirming bundle-root `--deep` verification missed them. All four embedded dynamic libraries, including two preview libraries, were re-signed and individually verified, followed by extensions and main app. No application code or data changed.
- The repaired in-place install succeeded. Air console showed main-app initialization and BLE `ready`; later checks found main and Live Activity processes alive. The user confirmed the app opened and the list looked normal, accepting device-list display. Real SIM changes and deletion still required tests. All 92 iOS tests passed with zero failures. ActivityKit `SessionCore.PermissionsError Code=3` was also observed; the launch fix did not establish resolution of Live Activity permissions.

## Shizuku startup prompts

- Standalone and AVF Bridge share startup checks after system permissions, offering official download, manager opening, or authorization for absent/stopped/unauthorized Shizuku. Ready state is silent; the current Activity launch and configuration recreation prompt at most once. Returning from external pages resumes startup, and crash reports wait until guidance finishes to avoid overlapping prompts.
- A startup-policy regression first reproduced `expected INSTALL but got NONE`. After repair it covered all three prompts, ready silence, background checks not being consumed, no repeat on return, and no repeat after recreation. Full phone-control/Standalone tests and 47 audio-bridge checks passed; both Debug APK builds/signatures passed. Existing Android deprecation, Java serial, and JDK native-access warnings remained, without compile errors.
- This round only generated APKs. It did not install, uninstall Shizuku, or revoke Samsung authorization. Device appearance and actions for absent/stopped/unauthorized prompts still needed testing; JVM policy tests are not system-permission-dialog acceptance.

## Known boundaries

### 2026-10-14 compatibility review fixes and per-pairing switch (unreleased at that point)

- The old Redmi Android 12 build crashed on VoBLE because `ByteArrayOutputStream.writeBytes` was unavailable. Nine pairing/fragment-reassembly sites changed to compatible writes. If VoBLE foreground-service startup is restricted, it logs failure and retries in the foreground rather than terminating on `IllegalStateException` or permission-revocation races. The earlier signed hotfix installed with data preserved and the user confirmed pairing.
- Six later review risks were fixed: Shizuku output API 35 `isEmpty`, URL Charset overloads, API 31 SMS factory, empty stream in PCM failure cleanup, API 34 AVF startup options, and old OEMs without `cmd audio`. Official NewApi scanning no longer reported these missing APIs; full scanning retained four existing permission diagnostics and three constant warnings, so full lint was not claimed green.
- Muting uses shell-package `AudioManager` with readback before success. Hang-up restores initial mute/volume and retains a snapshot for retry on failure. Regressions cover ignored mute, initially muted state, repeated mute, failed unmute, and successful unmute with failed volume restoration; the latter no longer falsely reports muted. Tests replace the platform audio boundary and do not change real-device call volume.
- Shared Android and Standalone tests passed, including API 29–35 SMS factory branches and null-service fallback without sending SMS; 47 PCM bridge checks passed. AVF/Standalone Debug builds passed with existing deprecation warnings.
- Redmi used `app_process` to load the new build for Bluetooth fragmentation/encryption, service refusal/retry, URL query, PCM failure cleanup, Shizuku output, and read-only audio-backend checks. URL decoding on the old installed build first reproduced `NoSuchMethodError`; the candidate path passed. Loading a test build does not mean the candidate APK was installed or real calls/SMS accepted. MIUI shell Context initialization printed missing-theme diagnostics, but read-only checks passed.
- iOS “Pair Android Phone” gained a local switch affecting only this pairing, not global mode. ON does not read cloud credentials and writes only VoWLAN; OFF explicitly fails for missing credentials. Pairing waits for in-flight Agent writes and blocks new writes so a late cloud POST cannot overwrite local configuration. Automatic sync recognizes local Agents; other global Relay-token refresh remains enabled. 97 iOS tests passed; the iPhone UI had not yet been installed for acceptance in that round.
- Release remained paused at that point, with no commit, push, GitHub Release, or TestFlight update. Android 10/11/13, other OEMs, real mute/volume restoration, bidirectional calls, and Apple Watch still required device validation.

### 2026-10-14 Android 11/12 startup compatibility fix (unreleased hotfix at that point)

- Xiaomi M2004J19C (Android API 31) and the supplied vivo V2111A stack (API 30, reported old version 0.1.0) both identified `BridgeLog.readFile` calling `ByteArrayOutputStream.toString(Charset)`, not damaged pairing data. Report content and user identifiers were not committed.
- Seven log/report/HTTP/WS decoding sites changed to compatible constructors; four VoWLAN/WS/cloud PCM fixed-length reads changed to `DataInputStream.readFully`. Short READY frames remain rejected without consuming later PCM. Bytecode regressions failed first, then passed; real diagnostic UTF-8 read/write, shared Android/Standalone tests, and 47 bridge checks passed.
- Launching the first repair on-device exposed unavailable `RuntimePermissionPolicy` `List.toArray(IntFunction)`. A method-reference check reproduced two failures; both changed to `toArray(new String[0])`. Full tests and the signed Standalone release build passed.
- The Xiaomi in-place installation used the production certificate and preserved data. After cold start, PID 11266 stayed alive across checks and reached MIUI permissions; built-in Agent and VoWLAN services were created. Home/pairing after permission selection, vivo device behavior, and real calls still awaited acceptance. No data was cleared or GitHub Release artifact replaced in that round.

### 2026-10-14 Apps v0.9.7 release verification

- Built from source commit `8bce6ac`, with Android/iOS version `0.9.7 (80)` and separate Linux Agent `0.4.6`. No new workflow or main-branch merge.
- All 92 iOS XTests, shared Android/Standalone suites, 47 bridge checks, Go Agent/installer tests, AVF Debian packaging tests, and 46 Relay tests plus syntax checks passed.
- AVF/Standalone Release APK signatures verified, with `debuggable=false` and certificate SHA-256 matching v0.9.6. Both iPhoneOS Release archives succeeded and nested main/Watch/Live Activity signatures verified; Xcode re-signs for App Store distribution.
- The public IPA was an unsigned Release build without provisioning profiles, not a reused Debug diagnostic package. TestFlight upload status depends on Xcode's result; successful Archive alone is neither upload nor approval.
- This round added no real carrier calls and deleted no user pairing data. Earlier device results and outstanding acceptance boundaries remained applicable.

- VoBLE is an independent mode, not a VoWLAN dependency. Established calls do not silently move among VoBLE, VoWLAN, and Relay.
- BLE carries only AirSIM control/audio; it does not implement Android-to-iPhone Bluetooth PAN internet sharing.
- Audio is G.711 μ-law 8 kHz mono; control and media use AES-256-GCM authentication. PCM is processed only in memory.
- iOS does not guarantee BLE background wake-up after user force-quit. CallKit supports local Bluetooth calls, but local mode does not depend on PushKit.
- Apple Watch uses iPhone CallKit/WatchConnectivity state and system audio routing, not a direct Watch-to-Android BLE audio link.
- Automation does not replace joint real-device call acceptance on Samsung, Xiaomi, iPhone, and Watch.
