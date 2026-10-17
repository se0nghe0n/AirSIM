# AirSIM Samsung Android Control App

This directory contains the shared Android implementation and legacy AVF compatibility Manifest. New installations should use the root [Android Standalone APK](../../android-standalone/README.md), which includes the Agent in the same APK. Use this AVF build entry point only for legacy deployments.

The documented release is [`v0.9.7.1`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1) (Android `versionCode 81`), with Android 10–13 compatibility fixes; upgrading is recommended. Prefer Standalone for new installs. The companion Linux AVF Agent remains [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6). The upstream maintainer's cloud mode uses `https://airsim-push.remotepilot.site`, not DJOneHub's `https://push.remotepilot.site`. Self-signed Apple clients need a separate Relay matching their Bundle ID and APNs credentials.

## Responsibilities

- Request and maintain the default phone app role.
- Monitor incoming, outgoing, connected, ended, and DTMF states.
- Send call and SMS events to the AVF Agent.
- Execute Agent commands for dialing, answering, rejecting, hanging up, and SMS.
- Provide a limited-time pairing window and six-digit confirmation code.
- Publish authenticated VoWLAN control and PCM services on the Samsung hotspot interface.
- Prefer VoWLAN control port `7592`. Audio is host-ICE WebRTC on that HMAC control link. Port `7593` is not a PCM listener. If `7592` is occupied, advertise the assigned control port through service discovery, avoiding DJOneHub's `7590/7591`.
- Maintain the foreground service, Shizuku state, and diagnostics.
- Check, install, and roll back signed Debian packages through the separate AVF installerd.
- Detect AVF, AOSP Linux Terminal, and AVF private-network readiness on startup, and provide a copyable one-command installer.
- Clearly show VoWLAN, cloud mode, cloud error, or offline status on the home screen; configuring Relay alone does not mean it is online.

## Default calling SIM

“Settings → Default Calling SIM” supports an enabled SIM/eSIM or “Follow System Default.” The local preference applies to BLE, VoWLAN, Relay, and Android local dialing without changing system call/SMS defaults. Relay registration and network connectivity are not required.

Reading available SIMs needs the existing phone-state permission; number-display permission is optional. Every dial uses a system `PhoneAccountHandle` and rechecks that the account is enabled. An unavailable selected SIM returns an explicit error without silently switching. This preference does not guarantee emergency-call routing.

## Requirements

- A Samsung Android test phone; target SDK 35.
- AirSIM selected as the default phone app.
- “Send SMS” permission granted and a default SMS SIM set on dual-SIM devices. Some Android versions grant this with the phone role; others require separate authorization.
- Official Shizuku manager running, with AirSIM authorized.
- Android AVF Agent reachable over the device's internal private network.
- Agent control token saved in app-private storage.

## Build and test

Run from the repository root:

```sh
./android/phone-control-app/test.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
```

Debug APK output:

```text
android/phone-control-app/build/android/AirSIM-Phone-Bridge-debug.apk
```

For releases, use a long-lived signing keystore outside the repository. Do not release with a debug keystore, which prevents safe upgrades later:

```sh
AIRSIM_ANDROID_BUILD_VARIANT=release \
AIRSIM_ANDROID_KEYSTORE=/absolute/path/to/airsim-android-release.jks \
AIRSIM_ANDROID_KEY_ALIAS=airsim-release \
AIRSIM_ANDROID_KEYSTORE_PASSWORD='injected from Secret Store' \
AIRSIM_ANDROID_KEY_PASSWORD='injected from Secret Store' \
./android/phone-control-app/build.sh
```

The release APK is `android/phone-control-app/build/android/AirSIM-Phone-Bridge-release.apk`. Never commit the keystore or passwords. Public releases must reuse the signing certificate to upgrade installed versions in place.

## Samsung phone setup

After initial permissions, the app checks Shizuku automatically. If absent, it shows official URL `https://shizuku.rikka.app/zh-hans/download/` and a download action; if installed but stopped, it offers to open the manager; if unauthorized, it offers authorization. No prompt appears when ready. It prompts at most once per launch and supports “Later.” Startup guidance, permissions, AVF readiness, and crash-report prompts are sequenced; the app does not install Shizuku automatically or bypass authorization.

1. Install the APK and open AirSIM.
2. If startup reports that AVF Linux is not running, select “Start Linux Terminal.” If Terminal is disabled, select “Open Developer Options” and enable the Linux development environment.
3. After Linux first starts, copy and execute the v0.4.6 first-install command in Terminal. Devices on `0.4.4-1` must first perform the [one-time key migration](../../docs/AVF_INSTALL_GUIDE.md) to v0.4.5, then upgrade through the installer. The old installer cannot skip key migration:

   ```sh
   bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'
   ```

4. Select AirSIM as the default phone app in system settings.
   Also allow “Send SMS” on first launch. “Read SMS” is an optional inbox fallback that scans only new messages after authorization; SMS broadcasts remain available if denied. For dual SIMs, set a default SMS SIM in system SIM settings. Missing send permission or default SMS SIM returns an explicit Agent error; SMS commands are never treated as call commands.
5. Start Shizuku and authorize AirSIM in its Shizuku section.
6. Run `sudo airsim-avf-pair` in Terminal, determine the Agent address on the current AVF private network, and save the printed control token in the app. Do not paste it into logs, screenshots, or the repository.
7. Confirm that the Agent, audio bridge, and VoWLAN are Ready.
8. Open the two-minute pairing window and enter the Samsung six-digit code on iPhone.

The installer command is always available under “Settings → AVF Linux Initial Installation.” **Copying does not execute it**; paste it at the Debian Terminal prompt and press Enter. Startup guidance appears only if AVF is stopped or if AVF is running but the Agent is unconfigured. “Agent reachable · Not paired” means only that the unauthenticated health check on `8575` passed; installation management and call control may not be ready. `installerd` also needs port `8576` and the control token. The repaired online bootstrap restores existing services when `current.deb` exists rather than refusing to run. Before release, manually inspect systemd services using the [AVF installation and non-destructive troubleshooting guide](../../docs/AVF_INSTALL_GUIDE.md); do not clear Linux Terminal data.

If Terminal reports `udev` requiring a newer `libudev1` or `unmet dependencies`, the problem is AVF Debian package state. Run `apt-cache policy udev libudev1` and `sudo apt-get -s -f install` in Terminal and inspect the simulated plan. Do not let the app or a script automatically run `apt --fix-broken install`.

## OEM compatibility boundaries

This hotfix adds older-API alternatives for URL UTF-8 encoding/decoding, Shizuku output, and PCM failure cleanup. The SMS factory branches at API 31 and retains the default SMS SIM. Legacy AVF mode on Android 10–13 uses a tappable notification to reopen Terminal; only API 34+ uses newer background-start options. Shizuku daemon version 8 avoids reusing the old mute implementation after upgrade. It calls `AudioManager` under the shell package identity, reads back mute state, restores prior mute/volume on hang-up, and retains a restoration snapshot on failure for retry. It does not falsely report successful muting; unsupported OEM behavior still requires user action.

Android 11/12 devices previously crashed on startup because `ByteArrayOutputStream.toString(Charset)` and `Collection.toArray(IntFunction)` were unavailable. Shared code now uses compatible UTF-8/ASCII decoding and array conversion; VoWLAN, Relay, PCM, and crash-report paths also replace `InputStream.readNBytes`. Both `test.sh` and APK builds inspect compiled method references to block these known incompatible calls. This is a targeted regression check, not full Android API lint; target-device acceptance is still required.

AirSIM recognizes Xiaomi, Redmi, OPPO, OnePlus, realme, vivo, iQOO, and Honor, distinguishing “Terminal installed but disabled,” “Terminal not installed,” and “AVF not exposed by the system.” It can open installed AOSP Linux Terminal or Developer Options, but a normal third-party app cannot restore a Terminal removed from OEM firmware, enable hidden AVF features, or bypass system-signature permissions. Those cases require an OEM update, a system image containing Terminal, or privileged-system integration by the OEM.

## Call and audio policy

Normal incoming calls default to `remote_silent`: Samsung remains under controlled mute while iPhone or Apple Watch presents the call and handles audio. Emergency calls always return to the preinstalled system phone app. The Shizuku service runs the audio bridge as the shell UID and restores previous system volume when the call ends.

As the default phone app, AirSIM also provides a separate Lock Screen incoming-call UI and notification actions for answering, rejecting, and hanging up; it shows no SMS or settings content. Incoming calls use a new high-priority notification channel because an existing low-priority foreground-service channel cannot be upgraded. Without full-screen call permission, it falls back to an actionable banner. Screen wake-up and lock-screen behavior require per-model device testing.

## Sending SMS

After iPhone submits SMS through VoWLAN or Relay, the AVF Agent sends `send_sms` to the Android Bridge. The Bridge uses the system SMS service and default SMS SIM to send segments, reporting success only after every segment receives a system “sent” receipt. This means the phone handed the message to the carrier, not that the recipient received it. On timeout or failure, inspect phone SMS history before retrying to avoid duplicates. SMS commands are independent of Telecom call-ID control.

## Network and security

- Agent configuration accepts only AVF private addresses. The subnet is dynamically assigned and must not be fixed to `10.185.5.0/24`. The app first infers the guest address from the `avf_tap_fixed` subnet; verify it on the current device.
- The bearer token is stored only in Android private preferences and never logged.
- VoWLAN binds only to a valid Samsung hotspot address, not general network interfaces.
- Every control request checks the route allowlist, message size, timestamp, nonce, and HMAC.
- Raw PCM, plaintext pairing data, and authentication material must not enter diagnostic logs.
- Agent API uses AVF port `8575`; the recovery installer uses `8576`. Both share the control token generated at bootstrap.
- Saved legacy AirSIM `:7575` addresses migrate to `:8575`. Port `7575` may belong to DJOneHub on the same device and is no longer evidence that AirSIM is online. Do not use old online packages for coexistence before the Agent port-migration release is published.
- Android management uploads only signed `airsim-avf-agent_*_arm64.deb` packages. Runtime capability detection handles chip-vendor differences without selecting different Debian packages.
- “Check and Install Latest Agent” selects exactly one `airsim-avf-agent_*_arm64.deb` and matching `.sig` from the latest GitHub Release of `kai-wu-cortex/AirSIM`. Missing packages/signatures, multiple packages, and non-HTTPS downloads are rejected.
