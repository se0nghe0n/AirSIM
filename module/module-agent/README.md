# AirSIM Android AVF Agent

The Agent runs in Samsung Android's AVF Linux environment and connects the Samsung control app, call audio bridge, Cloudflare Relay, and iPhone/Apple Watch clients.

The Agent release documented here is [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6) (Debian package `0.4.6-1`), paired with Android/iOS app release [`v0.9.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.6). The upstream maintainer's Relay is `https://airsim-push.remotepilot.site`; `https://push.remotepilot.site` belongs exclusively to DJOneHub.

For first installation, control-token pairing, an Agent reachable on `8575` with an unavailable installer on `8576`, and non-destructive Terminal startup troubleshooting, see the [AVF installation guide](../../docs/AVF_INSTALL_GUIDE.md). A successful `/api/health` does not establish installer or pairing readiness.

## Responsibilities

- Expose call, SMS, device-status, and diagnostic APIs.
- Receive Telecom and SMS events from Samsung Android.
- Dispatch dial, answer, reject, hang-up, DTMF, and SMS commands to the Samsung control app.
- Manage Relay heartbeats, device registration, cloud commands, and call media.
- Validate the Android control token and restrict callers to the private network.
- Monitor the Samsung PCM backend and report media health.

## Build and test

```sh
(cd module/module-agent && go test ./...)
(cd module/avf-installerd && go test ./...)
./module/packaging/test.sh
```

Deploy the single `arm64` Debian package produced by `module/packaging/build-avf-deb.sh` at the repository root. The Agent installs to `/usr/bin/airsim-agent`; the separate recovery installer installs to `/usr/lib/airsim/airsim-installerd`.

## Required configuration

```sh
AIRSIM_RUNTIME_PROFILE=android-avf
AIRSIM_VOICE_BACKEND=samsung_android
AIRSIM_SAMSUNG_PCM_ADDRESS=<AVF_PRIVATE_IP>:7580
AIRSIM_DATA_DIR=/var/lib/airsim
AIRSIM_ANDROID_CONTROL_TOKEN_FILE=/var/lib/airsim/control.token
```

Only the Agent service account may read the control-token file. Do not commit private addresses or tokens, or include them in public logs.

## Cloud Relay configuration

The Agent does not hard-code a public domain; it uses the `relay_url` supplied through iPhone pairing registration. The upstream maintainer's `com.eric3u.airsim` build uses `https://airsim-push.remotepilot.site`, while DJOneHub continues to use `https://push.remotepilot.site`. Their Workers, KV, Durable Objects, device identities, commands, and media sessions are separate. The AirSIM Agent must not connect to the DJOneHub Relay.

Deployers who re-sign the app must configure their own Relay URL, `ALLOWED_BUNDLE_ID`, and APNs credentials. A successful Relay `/healthz` proves only that the Worker is reachable; validate device registration, Agent heartbeats, command fetching, APNs, and media WebSockets separately.

## Startup verification

Run before restarting the production service:

```sh
AIRSIM_RUNTIME_PROFILE=android-avf \
AIRSIM_VOICE_BACKEND=samsung_android \
AIRSIM_SAMSUNG_PCM_ADDRESS=<AVF_PRIVATE_IP>:7580 \
/usr/bin/airsim-agent --startup-probe voice-backend
```

The probe validates configuration, the private address, TCP connectivity, and the `AIRSIMPCM1` / `AIRSIMREADY` handshake.

## Samsung control app interface

The Samsung app uses protected `/api/android/*` endpoints for:

- Pairing registration
- Call and SMS event reporting
- Command long polling
- Command result reporting
- Health and capability queries

External clients must not access AVF internal control addresses directly. The Samsung app authenticates VoWLAN requests, applies route allowlists and response-size limits, then forwards them.

VoWLAN answer, reject, and hang-up requests may include JSON `call_id`, matching the active call's `id` from `/api/calls/status`. The Agent rejects expired or mismatched IDs so an old notification cannot control a new call. Requests from older clients without this field retain the compatibility path.

## Security and operations

- The runtime configuration is fixed to `android-avf` and `samsung_android`.
- Logs omit Android control request bodies, SMS content, device secrets, and PCM data.
- Release Relay, Android app, and Agent protocol-field changes together.
- Before production deployment, validate real Samsung calls, SMS, restart recovery, and long-term stability.
- The Agent no longer installs its own updates. The Android app uses the separate `airsim-installerd` for signature verification, installation, health checks, and rollback.
