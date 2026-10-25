# AirSIM shared Android application

This directory contains the Java application and shared build/test tooling for [Android Standalone](../../android-standalone/README.md). Standalone is the only runtime; the AVF HTTP client, Linux watchdog, installer and recovery screens have been removed.

## Build and test

Set `ANDROID_SDK_ROOT` to an SDK with Android 35 and Build Tools 35.0.0, and use JDK 17 or newer.

```sh
./android/phone-control-app/test.sh
./android/phone-control-app/build.sh
./android/phone-control-app/verify-apk.sh
```

The default build uses `android-standalone/AndroidManifest.xml` and writes `build/android/AirSIM-Android-Standalone-debug.apk` here. The recommended wrapper `./android-standalone/build.sh` uses the same manifest and package and writes to `android-standalone/build/android/`. Release signing variables are documented in the Standalone guide. Keep package identity, signing certificate and stored data on upgrades.

## Runtime

- `StandaloneBridgeApplication`, boot and Telecom/SMS receivers start `StandaloneAgentService` directly.
- `AgentClient` calls the in-process `StandaloneAgentGateway`; local VoWLAN forwards authenticated requests to the same implementation. No Linux control endpoint or token is needed.
- The Agent owns pairing, persistent SMS delivery, cloud heartbeats, command execution and call history. The existing storage formats and wire APIs are retained.
- Shizuku owns privileged native WebRTC and carrier audio. Read [the media migration gates](../../docs/webrtc-only-migration.md) before claiming device acceptance.
- Default calling SIM selection uses Android Telecom and leaves the system default unchanged. An unavailable selected SIM is an explicit error.
- SMS sending uses platform confirmation; local acknowledgement preserves pending cloud delivery. Optional inbox fallback reads only newly received messages and does not bulk-import historical SMS.
- VoWLAN requires the same LAN or hotspot, pairing credentials, HMAC authentication, replay protection and bounded requests. Emergency calls remain the responsibility of system telephony.

See [Standalone migration](../../docs/standalone-migration.md) for existing AVF data and upgrade boundaries. Historical audio-bridge process matching is retained only to stop stale processes owned by this package; it is not an AVF startup path.
