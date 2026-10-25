# AirSIM development and validation guide

Read the root README, component README, and actual source/tests before changing behavior. Android Standalone is the only runtime. `module/module-agent`, `module/avf-installerd`, Debian packaging, Linux bootstrap and recovery paths have been removed.

## Architecture and data contract

- Android source is in `android/phone-control-app`; its default build and `android-standalone/build.sh` use `android-standalone/AndroidManifest.xml`.
- Preserve package `com.airsim.phonecontrol.pixel8pro`, signing identity, Agent device IDs, private preferences, pairing secrets, pending SMS and deduplication records. Never uninstall or clear data as a routine upgrade step. Read `docs/standalone-migration.md`.
- `AgentClient` invokes `StandaloneAgentGateway` in process. The foreground service owns Relay registration, heartbeats, durable SMS delivery and commands. No HTTP client may reconnect to Linux ports 8575/8576.
- Pairing and VoWLAN wire contracts remain stable. Local controls require timestamp/nonce/HMAC validation, route allowlists and size bounds. Local and cloud calls keep one transport for their lifetime.
- Shizuku owns native WebRTC and carrier audio in one privileged process. Audio never crosses Binder, pipe, WebSocket or DataChannel as raw samples. Do not restore PCM fallback.
- Watch controls iPhone audio. Real Q25/Pixel carrier routing, repeated calls, backgrounding and teardown remain physical acceptance gates in `docs/webrtc-only-migration.md`.
- The historical audio bridge has been removed. Package-scoped old-daemon matching remains for upgrade safety; it never starts a legacy process. Routing evidence is tracked in `docs/carrier-route-validation.md`. Archived release notes describe their original versions.
- Existing AVF device data is not automatically imported. Do not stop or purge an installed service or delete cloud records merely because its source has been removed.

## Workflow

1. Inspect git status and preserve unrelated changes.
2. Trace all producers, consumers, persistent fields and tests for a changed contract.
3. Keep changes bounded and verify behavior, including data preservation.
4. Run the appropriate tests and builds. Report actual results and unexecuted device/deployment gates.

```sh
# Set ANDROID_SDK_ROOT to the installed SDK; requires platform/build tools 35 and JDK 17+.
./android-standalone/test.sh
./android/phone-control-app/build.sh
./android/phone-control-app/verify-apk.sh
(cd push-relay-worker && npm test && npm run check)
```

Use Xcode tooling for Apple builds/tests, including the iPhone, Watch and Live Activity targets. Simulator builds cannot establish carrier audio, physical CallKit/PushKit lifecycle or public APNs delivery.

## Security and external actions

- Never expose secrets, signing keys, APNs `.p8`, Agent tokens, pairing/HMAC material, SMS bodies, real phone numbers or audio in source, logs or reports. Inject release credentials through approved secret storage.
- The maintainer AirSIM Relay is `https://airsim-push.remotepilot.site`; `https://push.remotepilot.site` belongs to DJOneHub. Keep domains, Workers, KV, Durable Objects, identities and APNs topics separate. Other signing identities require their own Relay and credentials.
- Preserve deployed Durable Object bindings and migration history. Source cleanup does not authorize deleting cloud data.
- Do not deploy, publish a release, install to physical devices or push Git without user authorization. Preserve existing signing identities and all Bundle ID relationships.
- AirSIM is source-available under PolyForm Noncommercial 1.0.0. Preserve LICENSE, NOTICE and third-party notices. Commercial use requires separate written permission.
- Emergency calling remains with system telephony; AirSIM does not replace a carrier or emergency service.
