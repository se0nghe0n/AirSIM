# AirSIM Android Call Audio Bridge

The recommended [Android Standalone APK](../../android-standalone/README.md) does not depend on AVF. Only legacy AVF compatibility mode requires separate verification of `8575`, `8576`, and the control token using the [AVF installation and non-destructive troubleshooting guide](../../docs/AVF_INSTALL_GUIDE.md). A PCM bridge waiting to start does not mean the Debian package is damaged and should not be addressed by clearing AVF data.

This component runs in an Android Shizuku `UserService`, accesses system call audio as the shell UID, and provides bidirectional PCM to the control app's built-in Agent or the legacy AVF Agent.

The application release baseline documented here is [`v0.9.2`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.2), with AVF Agent [`v0.4.5`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.5). Cloud media connects only to a Relay matching the current AirSIM signing identity. The upstream maintainer's address is `https://airsim-push.remotepilot.site`, not DJOneHub's `https://push.remotepilot.site`.

The bridge selects available audio capabilities rather than enforcing a particular phone model. This fork is verified on Zinwa Q25 and Pixel 8 Pro; required privileges and OEM audio-route availability still constrain compatibility. See [compatibility scope](../../README.md#android-compatibility-and-verification).

## Audio directions

- Downlink: `AudioRecord.VOICE_DOWNLINK` → Agent / Relay → iPhone or Apple Watch
- Uplink: iPhone or Apple Watch microphone → Agent / Relay → `USAGE_VOICE_COMMUNICATION` with Samsung `VOICE_TX` or an available Android telephony Tx device
- Format: 8 kHz, mono, PCM16LE, 320 bytes per frame
- Handshake: `AIRSIMPCM1\n` / `AIRSIMREADY`

The bridge does not save PCM. JSONL logs contain only lifecycle events, routes, frame counts, byte counts, peaks, and errors.

## Build and test

```sh
./android/phone-audio-bridge/build.sh
```

The build also runs JVM unit tests and outputs:

```text
android/phone-audio-bridge/build/airsim-phone-audio-bridge.jar
```

## Legacy AVF deployment

The manual runner below is for legacy AVF deployments. The bridge must bind to the Android AVF private interface. Resolve the current address after every AVF startup:

```sh
adb -s DEVICE shell 'ip -o -4 addr show avf_tap_fixed'
ssh -p 2222 droid@127.0.0.1 'ip route'
```

Start and inspect:

```sh
ADB=/path/to/adb ADB_SERIAL=DEVICE LISTEN_HOST=AVF_ANDROID_IP \
  ./android/phone-audio-bridge/run-device-bridge.sh start
ADB=/path/to/adb ADB_SERIAL=DEVICE \
  ./android/phone-audio-bridge/run-device-bridge.sh status
ADB=/path/to/adb ADB_SERIAL=DEVICE \
  ./android/phone-audio-bridge/run-device-bridge.sh logs
```

The runner rejects wildcard addresses, external Wi-Fi, hotspot, cellular, and other interfaces outside the AVF private network.

## Agent configuration

Example systemd environment:

```ini
[Service]
Environment=AIRSIM_VOICE_BACKEND=samsung_android
Environment=AIRSIM_SAMSUNG_PCM_ADDRESS=AVF_ANDROID_IP:7580
```

Run the handshake probe before startup:

```sh
AIRSIM_RUNTIME_PROFILE=android-avf \
AIRSIM_VOICE_BACKEND=samsung_android \
AIRSIM_SAMSUNG_PCM_ADDRESS=AVF_ANDROID_IP:7580 \
/usr/local/bin/airsim-agent --startup-probe voice-backend
```

## Runtime boundaries

- Only one authenticated client may hold the current call's PCM session.
- Close both streams immediately when the call ends, the hotspot changes, or either direction disconnects.
- Android may terminate the shell process; the control app's Shizuku manager detects this and restarts the service.
- Real bidirectional voice must be validated together with Android Telecom control, the AVF Agent, and the iOS/watchOS client.
