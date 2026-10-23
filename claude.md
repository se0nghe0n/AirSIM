# AirSIM whole-project Claude deployment guide

You are working on AirSIM: a multi-endpoint project that uses a Samsung Android phone to carry cellular calls and SMS, and lets an iPhone / Apple Watch use those capabilities over VoWLAN or Cloudflare Relay.

Current release baseline (2026-10-14): Apps `v0.9.7.1`, Android `0.9.7.1 (81)`, iOS `0.9.7 (81)`. For the Android 10–13 fix, installing Standalone is recommended. The compatible AVF Agent stays at `v0.4.6` (Debian `0.4.6-1`), and the Relay protocol stays at `0.2.1`. The GitHub IPA is an unsigned package meant for re-signing. The maintainer uploads TestFlight separately through Xcode; upload, processing, and review status must not be conflated. The maintainer AirSIM Relay is `https://airsim-push.remotepilot.site`. DJOneHub's `https://push.remotepilot.site` must not be used for AirSIM. Old version numbers in historical Release documents are archival facts and must not be mechanically replaced.

Changes in this version: the local pairing switch on iOS “Pair Android phone” controls only the current configuration package and does not write the global mode. Agent auto-registration must protect that local configuration, and pairing must be serialized with in-flight Agent writes. The Android API 29+ compatibility branch is described in the shared README. Legacy AVF recovery below API 34 uses a tappable notification and does not call the newer ActivityOptions methods. Cloud hang-up generation isolation and PCM jitter improvements are in `docs/cloud-pcm-resilience.md`. Users have reported that, on devices this round, the hang-up UI no longer reproduces and audio is more stable. That does not constitute acceptance across all device models, weak networks, or Watch.

## Before you start

Complete these in order:

1. Read the root `README.md`.
2. Read the target subdirectory's `README.md`, source, and tests.
3. Run `git status --short` and keep the user's existing changes.
4. Use `rg` to find every reference to cross-endpoint protocols, environment variables, ports, or Bundle IDs.
5. Change only the files the task needs, and update the related tests and docs.
6. Install, pairing, or recovery tasks also require reading `docs/AVF_INSTALL_GUIDE.md` and `LLM.txt`. Future related changes must update the root and component READMEs, the install guide, `LLM.txt`, `codex.md`, and `claude.md`.

Do not rely on old brands, old deployment hostnames, or remembered Cloudflare/Apple behavior. The current source and pinned versions are the source of truth.

## System boundaries

- `android-standalone`: the recommended single-APK build entry. It reuses the Android implementation, enables the built-in Agent, and does not depend on AVF Linux.
- `android/phone-control-app`: Samsung default-phone role, Android Telecom, SMS, VoWLAN, pairing, AVF startup guidance, and install management.
- `android/phone-audio-bridge`: Shizuku `UserService` for bidirectional call PCM.
- `module/module-agent`: device state, control API, Relay, and media orchestration inside AVF Linux.
- `module/avf-installerd`: an independent rescue installer that installs only Debian packages that pass signature and package-metadata checks.
- `module/packaging`: a single `arm64` Debian package, systemd units, signing, and the first-install script.
- `iOS`: iPhone, Apple Watch, CallKit, PushKit, ActivityKit, SMS, and transport selection.
- `push-relay-worker`: Cloudflare Worker, KV, Durable Objects, APNs, Dashboard, and WebSocket.

A cross-component protocol change must update the producer, consumer, models, tests, and docs together. Do not leave only one side compiling.

## Mandatory security rules

1. The AVF Agent, installerd, and PCM may listen only on an internal private network or loopback.
2. VoWLAN must keep timestamps, nonces, HMAC, the route allowlist, and size limits.
3. Call PCM is not written to disk by default. Only an iPhone recording the user explicitly turns on may be written to a protected local file excluded from backup, and it must not be uploaded. Logs must not contain PCM, full SMS bodies, Push tokens, or Secrets.
4. The Agent must not update itself. Updates, repairs, and rollbacks may be performed only by the independent installerd.
5. installerd must not run an arbitrary shell, and must not accept a wrong package name, a non-`arm64` package, or an unsigned package.
6. Emergency calls are handed to the system phone capability. Do not claim that AirSIM can carry emergency communications.
7. A normal Android app cannot bypass OEM or system-signature limits to force-enable an AVF feature that has been hidden or removed.
8. AVF `/api/health` only proves the Agent is reachable. `8576` installerd, the control token, and the real phone path must be verified separately. Do not hard-code a single AVF subnet, and do not clear Terminal data or delete `current.deb` as a routine fix.

v0.4.5 is a signing trust-root migration. The v0.4.4 private key was not retained, so the old installerd rejects the new signature. Devices that already have `0.4.4-1` must run the reviewed `rotate-avf-key.sh` in the AVF Terminal, keep the old package and state, and only then resume in-app signed updates. The new release private key exists only in restricted storage outside the repository and in the GitHub Actions Secret `AIRSIM_RELEASE_PRIVATE_KEY_PEM`. Signing operations must not echo or commit the private key. The steps are in `docs/AVF_INSTALL_GUIDE.md`.

Never commit or echo: `APNS_P8`, `DASHBOARD_TOKEN`, Cloudflare API tokens, Apple `.p8` files, device Secrets, Agent tokens, HMAC material, the Debian release private key, the Android keystore, Apple certificates/profiles, real phone numbers, or SMS content.

## Apple signing rules

`com.example.airsim` is a placeholder in the source repository. Each deployer must reconfigure it with their own Apple Developer Team:

- Main app: the deployer's unique Bundle ID.
- Watch App: the main Bundle ID plus `.watchkitapp`.
- Live Activity: the main Bundle ID plus `.liveactivity`.
- Test target: the main Bundle ID plus `.tests`.
- Watch companion identifier: equal to the main app Bundle ID.
- Relay `ALLOWED_BUNDLE_ID`: equal to the main app Bundle ID.

Changing only the Team or signing certificate while keeping someone else's Bundle ID does not work. A Debug token corresponds to the APNs sandbox. A TestFlight/App Store token corresponds to production. They must not be mixed.

## Relay rules

Producers must use their own Cloudflare account, KV, Durable Objects, and custom domain. The maintainer AirSIM Worker is `airsim-push-relay`, at `https://airsim-push.remotepilot.site`, and allows only `com.eric3u.airsim`. It is not a public service for third-party re-signed apps. DJOneHub's `https://push.remotepilot.site` must stay independent. AirSIM must not take over its hostname, KV, Durable Objects, or Dashboard token. Clients and the Agent must not treat any historical hostname as a hard-coded dependency.

As of 2026-10-08, the maintainer deployment has completed only the health check and Dashboard authentication acceptance. The AirSIM environment has no device registrations yet. Do not claim on that basis that real APNs, Agent heartbeats, or cloud PCM have passed.

`APNS_P8` and `DASHBOARD_TOKEN` are required Worker Secrets:

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

In `wrangler.example.toml`, `[secrets] required` declares names only and stores no values. Secrets must not be written into `[vars]`, Git, build artifacts, or logs. Running `secret put` and a production `deploy` changes external state and may be done only when the user explicitly asks.

## License boundary

AirSIM uses `PolyForm-Noncommercial-1.0.0`. It authorizes only personal study, research, experimentation, and the other noncommercial uses named in the license. Do not describe the project as OSI open-source software, and do not help use AirSIM for paid services, commercial products, internal business purposes, or other expected commercial applications unless the user can provide a separate written commercial license from the copyright holder. Modifications, builds, and redistribution must keep the root `LICENSE`, `NOTICE`, and applicable third-party notices.

## Standard verification

```sh
./android/phone-control-app/test.sh
./android/phone-audio-bridge/build.sh
./android/phone-control-app/build.sh
sh ./android/phone-control-app/verify-apk.sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
(cd push-relay-worker && npm test && npm run check)
xcodebuild -project iOS/AirSIM.xcodeproj -scheme AirSIM \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Run the smallest sufficient verification for the change. When a protocol or shared configuration changes, run tests on both sides. Before a release, run the full suite. Documentation changes must at least run `git diff --check`, a relative-link check, and a sensitive-value scan.

## Deployment order

1. Build and install the Samsung Android app, set the default phone role, and authorize Shizuku.
2. Start AVF Linux and, following `docs/AVF_INSTALL_GUIDE.md`, run the signed install command with `pipefail` and a timeout in the Debian Terminal. The app button only copies the command and cannot run it inside the guest system for the user. If `current.deb` already exists and `8576` is unavailable, restore installerd rather than deleting the rollback package. Run `sudo airsim-avf-pair` and save the current dynamic AVF address and control token. A fix in the source bootstrap script enters the live command only after a new Release is explicitly authorized.
   If `udev` and `libudev1` report an exact-version dependency conflict, first read the simulated results of `apt-cache policy` and `sudo apt-get -s -f install`. Do not automatically run `apt --fix-broken install`. The bootstrap script must check the existing Debian package state before installing the Agent.
3. Separately verify the `8575` AirSIM Agent (`product=airsim`), `8576` installerd, the audio bridge, and the Android Telecom control plane. Existing DJOneHub stays on `7575`. An older AirSIM Release conflicts with it and cannot be used for a side-by-side install. For Terminal `VM is not in stopped state`, first investigate the startup conflict without data loss. Do not attribute it to the Agent package.
4. Configure and sign the iOS/watchOS project with the deployer's own Apple identity.
5. If remote mode is needed, create independent Relay resources, set the Secrets, dry-run, and then deploy.
6. Verify VoWLAN first, then the public Relay, APNs sandbox/production, and the Watch path.
7. Complete acceptance for Samsung incoming and outgoing calls, SMS, bidirectional audio, background wake, network loss, reboot, and rollback.

## Report format

The final reply must distinguish:

- What was changed and what was verified.
- On-device or production operations that have not been run.
- Account, device, signing, or domain conditions the user must provide.
- Known risks and the next step.

Do not describe a dry-run as a successful deployment, a simulator build as on-device availability, or a capability present in code as having passed carrier-network acceptance.
