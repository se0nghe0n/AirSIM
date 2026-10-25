# AirSIM Cloudflare Relay Deployment Guide

`push-relay-worker/` contains a deployable Relay backend, not placeholder domain files. It provides public-network control, APNs push, status synchronization, command queues, and authenticated call signaling between AirSIM iPhone, Apple Watch, Live Activity, and the Android Standalone built-in Agent. AirSIM and DJOneHub must use separate Workers, KV, Durable Objects, and domains. The upstream maintainer's production AirSIM domain is `https://airsim-push.remotepilot.site`; other deployers should use their own Cloudflare custom domain.

> Replace the domains, Cloudflare resources, Apple Team ID, and keys in this guide with your own. Never reuse another AirSIM environment's KV, Durable Objects, Dashboard token, device secret, or APNs private key.

## Recorded upstream deployment status (2026-10-09)

| Item | Status |
| --- | --- |
| Worker | `airsim-push-relay` |
| Custom Domain | `https://airsim-push.remotepilot.site` |
| `ALLOWED_BUNDLE_ID` | `com.eric3u.airsim` |
| Worker protocol version | `/healthz` reports `0.2.1` |
| Companion app release | [`v0.9.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.6) |
| Storage | AirSIM-specific `DEVICES` KV and `MEDIA`, `STATUS`, `COMMANDS` Durable Objects |
| Secrets | `APNS_P8` and `DASHBOARD_TOKEN` names configured; values are not in the repository |
| DJOneHub isolation | `https://push.remotepilot.site` still returns `djonehub-push-relay` |

AirSIM `/healthz` was verified to return `airsim-push-relay`; the Dashboard API returned `401` anonymously and `200` with the correct Bearer token. Device and event counts were both zero at that check. This establishes infrastructure, routing, and Dashboard authentication readiness only, not real device registration, PushKit/APNs, Agent heartbeats, commands, or PCM media acceptance.

This URL serves only the maintainer's signed `com.eric3u.airsim` builds, not public multi-tenant access. Deployers using their own Apple Developer Team and Bundle ID must create their own Worker, KV/DO, hostname, Secrets, and APNs configuration.

## 1. Repository implementation

Main files:

| File | Purpose |
| --- | --- |
| `src/index.mjs` | HTTP/WebSocket API, device authentication, APNs JWT/push, commands, and WebRTC signaling |
| `src/status-store.mjs` | Device, heartbeat, Relay status, and Dashboard-event persistence |
| `src/dashboard.mjs` | Protected operations dashboard and virtual incoming-call test |
| `wrangler.example.toml` | Cloudflare Worker, KV, Durable Objects, and variable template |
| `test/relay.test.mjs` | Registration, authentication, push, command, and protocol tests |

The backend includes:

- `POST /v1/devices/register`: iPhone/Watch/APNs token self-registration.
- `POST /v1/live-activities/register`: Live Activity update-token registration.
- `POST /v1/events/call`, `/call-owner`, `/call-state`, `/sms`: incoming-call, call-state, and SMS events.
- `POST /v1/events/heartbeat`, `/v1/devices/status`: Agent heartbeat and device status.
- `/v1/commands/*`, `/v1/calls/:uuid/actions*`: device commands and call actions.
- `/v1/calls/:uuid/connect`, `/v1/devices/:deviceID/commands/connect`: authenticated WebSockets.
- `GET /healthz`, `GET /dashboard`: health check and operations UI.

`POST /v1/commands/enqueue` also accepts the read-only `call_history` type with a device ID/secret, UUID command ID, and optional `limit` from 1 to 100 (default 100). Omit number, message, call, and action fields. It creates no cellular call. Fetch completion through `/v1/commands/result`; `result.history` contains native Android records with stable agent/provider IDs and ISO 8601 timestamps. Permission/provider failures are explicit failed results. Responses are bounded below the command WebSocket frame limit.

Storage responsibilities:

- `DEVICES` KV: recovery mirrors of devices/status and short-lived Relay data.
- `STATUS` Durable Object: authoritative device registration, Agent heartbeats, and Dashboard events.
- `COMMANDS` Durable Object: per-device command queues, results, and command WebSockets.
- `MEDIA` Durable Object: authenticated signaling/control sessions for individual calls, not an audio tunnel. The deployed binding and migration history stay unchanged.

## 2. Apple prerequisites

### 2.1 Apple Developer and device signing

You need a valid Apple Developer Program team and a Mac for device debugging. This source-available, noncommercial repository includes no original-author App IDs, team access, certificates, or provisioning profiles. `com.example.airsim` is a placeholder and cannot be released directly. Every deployer must replace it with a unique reverse-domain identifier they control and sign with their own Apple Developer Team.

For example, someone controlling `example.org` could choose `org.example.airsim`. Create three Explicit App IDs for the main app, Watch app, and Live Activity Extension:

| Target | Placeholder Bundle ID | Replacement rule |
| --- | --- | --- |
| AirSIM | `com.example.airsim` | Your own main Bundle ID, such as `org.example.airsim` |
| AirSIMWatchApp | `com.example.airsim.watchkitapp` | Main Bundle ID plus `.watchkitapp` |
| AirSIMLiveActivityExtension | `com.example.airsim.liveactivity` | Main Bundle ID plus `.liveactivity` |

Before the first build, update all of the following:

1. Team and Bundle Identifier for all three targets under Xcode → Signing & Capabilities.
2. Watch target `WKCompanionAppBundleIdentifier`, matching the new main app Bundle ID.
3. `ALLOWED_BUNDLE_ID` in `wrangler.toml`, matching the new main app Bundle ID.
4. The three Explicit App IDs, capabilities, and provisioning profiles in Apple Developer.
5. Actual Debug/Release signing entitlements, Relay registration fields, and all APNs topics.

Do not try to register or sign historical original-author identifiers; source users do not own them. Changing only `DEVELOPMENT_TEAM` is insufficient. Change all three Bundle IDs, the Watch companion relationship, and the Relay allowlist together.

The main and Watch apps require Push Notifications capability. Main-app Background Modes must include Voice over IP and Remote notifications; the project also uses background audio. The Live Activity target requires correct ActivityKit configuration.

The repository's main app entitlements include:

```xml
<key>aps-environment</key>
<string>$(APS_ENVIRONMENT)</string>
```

Debug currently maps to `development` and Relay APNs `sandbox`; Release maps to `production`. Inspect the final entitlements in the signed `.app`, not just source:

```sh
codesign -d --entitlements :- /path/to/AirSIM.app
```

`com.apple.developer.calling-app` and `com.apple.developer.messaging-app` are Apple-managed entitlements. Include them in signed products only if your team is authorized and provisioning profiles contain them. Otherwise, complete Apple's capability application or remove them from the target configuration. Ordinary CallKit UI and PushKit VoIP server workflows do not automatically grant either managed entitlement.

### 2.2 CallKit, PushKit, and certificates

- **Development/distribution certificates and provisioning profiles:** Sign the app, permit device installation, and embed the correct `aps-environment` entitlement.
- **PushKit:** iPhone obtains a VoIP token through `PKPushRegistry`; on receiving a VoIP push, the app must promptly report the incoming call to CallKit.
- **CallKit:** Manages system incoming-call UI and call lifecycle; it has no separate Relay server certificate.
- **APNs server authentication key:** The Relay uses Apple Developer's `AuthKey_<KEY_ID>.p8`, Key ID, and Team ID to create an ES256 provider JWT and connect to APNs.

This project uses APNs token-based authentication, not a `.p12` TLS certificate. Enable Apple Push Notifications service when creating the key on Apple Developer's Keys page; download `.p8`, record the Key ID, and obtain Team ID from Membership. The `.p8` is generally downloadable only once; store it in a password manager and never commit it.

APNs topics used by the Relay:

| Scenario | `apns-push-type` | Topic |
| --- | --- | --- |
| iPhone incoming call | `voip` | `${ALLOWED_BUNDLE_ID}.voip` |
| Watch incoming call | `voip` | `${ALLOWED_BUNDLE_ID}.watchkitapp.voip` |
| Normal notification/SMS | `alert` or `background` | `${ALLOWED_BUNDLE_ID}` |
| Live Activity | `liveactivity` | `${ALLOWED_BUNDLE_ID}.push-type.liveactivity` |

The Relay selects `api.sandbox.push.apple.com` or `api.push.apple.com` using registration `environment`. Development-signed tokens cannot be sent to production; TestFlight/App Store production tokens cannot be sent to sandbox.

## 3. Cloudflare prerequisites

You need:

- A Cloudflare account; for custom domains, the domain's zone must belong to that account.
- Node.js 20 or newer.
- The Wrangler version locked in this directory, invoked through `npx wrangler` to avoid global-version differences.
- A new KV namespace; configured migrations create Durable Objects on first deployment.

Install dependencies and log in:

```sh
cd push-relay-worker
npm ci
npx wrangler login
npx wrangler whoami
```

Do not use interactive login in CI. Supply a least-privilege Cloudflare API token as a CI Secret, never in the repository.

## 4. Create Wrangler configuration

### 4.1 Create KV

```sh
npx wrangler kv namespace create DEVICES
```

The command returns a namespace ID. Copy the template:

```sh
cp wrangler.example.toml wrangler.toml
```

Then edit `wrangler.toml`:

```toml
[vars]
APNS_TEAM_ID = "YOUR_APPLE_TEAM_ID"
APNS_KEY_ID = "YOUR_APNS_KEY_ID"
ALLOWED_BUNDLE_ID = "org.example.airsim"
WEBRTC_TRANSPORT_READY = "false"
WEBRTC_ROLLOUT_PERCENT = "0"
NEW_DEVICE_ENROLLMENT_ENABLED = "false"

[[kv_namespaces]]
binding = "DEVICES"
id = "YOUR_KV_NAMESPACE_ID"
```

Do not rename code-dependent `DEVICES`, `MEDIA`, `STATUS`, or `COMMANDS` bindings, or remove/reorder existing Durable Object migration tags. After the first production deployment, append new migration tags for subsequent schema changes.

### 4.2 Configure a custom domain

For production, disable `workers.dev` and configure a Custom Domain:

```toml
workers_dev = false

[[routes]]
pattern = "airsim-push.remotepilot.site"
custom_domain = true
```

Replace the example `pattern` with an AirSIM-specific hostname such as `airsim-push.remotepilot.site` or `airsim-push.example.com`. Cloudflare creates DNS records and issues a certificate for a Custom Domain; the hostname must not have a conflicting CNAME. Do not bind the AirSIM Worker to DJOneHub's active `push.remotepilot.site`, or reuse its KV, Durable Objects, or Dashboard token.

### 4.3 Add Secrets

Ordinary variables can live in `wrangler.toml`, but these two values are **required Worker Secrets**:

| Secret name | Contents | Purpose |
| --- | --- | --- |
| `APNS_P8` | Complete PEM text from Apple `AuthKey_<KEY_ID>.p8`, including BEGIN/END lines | APNs provider JWT; must belong to the same Apple Team as `APNS_KEY_ID` and `APNS_TEAM_ID` |
| `DASHBOARD_TOKEN` | Independent random Bearer token from a password manager, preferably at least 32 random bytes; not a Cloudflare API token | Protects `/dashboard/api/summary` and `/dashboard/api/virtual-call` |

The `wrangler.toml` declaration is:

```toml
[secrets]
required = ["APNS_P8", "DASHBOARD_TOKEN"]
```

This **declares Secret names only**; it neither sets nor uploads their values. Wrangler recognizes required Secrets during local development/type generation and checks for missing values at deployment. Never put the following in `wrangler.toml` or `[vars]`:

```toml
# Incorrect example: never commit real values
APNS_P8 = "-----BEGIN PRIVATE KEY-----..."
DASHBOARD_TOKEN = "real-administration-token"
```

#### Add interactively to Cloudflare

Finish account resources, Bundle ID, and domain configuration in `wrangler.toml`, then run:

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

At the first prompt, paste the complete multiline `.p8`; at the second, paste the random password-manager token. `secret list` shows names only, not values. The documented `wrangler secret put` behavior creates and immediately deploys a new Worker version, so adding, changing, or rotating Secrets in a live environment is a production release.

For gradual version deployments, use this instead of `secret put`:

```sh
npx wrangler versions secret put APNS_P8 --config wrangler.toml
npx wrangler versions secret put DASHBOARD_TOKEN --config wrangler.toml
```

This creates a new version only; publish it later through the version-deployment process.

#### Upload both Secrets together for first deployment or CI

To avoid two updates, create a temporary Git-ignored `.env.production` locally or in CI:

```dotenv
APNS_P8="-----BEGIN PRIVATE KEY-----\ncomplete-private-key-contents\n-----END PRIVATE KEY-----"
DASHBOARD_TOKEN="random-value-from-password-manager"
```

Then upload code and both Secrets together:

```sh
npx wrangler deploy \
  --config wrangler.toml \
  --secrets-file .env.production
```

CI should generate this temporary file from its Secret Store and destroy it afterward, without putting it in caches or artifacts. `--secrets-file` is incremental: existing Secrets omitted from the file are retained, not deleted.

#### Local development

Local `wrangler dev` can use an uncommitted `.dev.vars`:

```dotenv
APNS_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
DASHBOARD_TOKEN="replace-with-a-local-only-random-token"
```

Do not mix `.env` with an existing `.dev.vars`. With `secrets.required`, only the two listed names load as Secrets, and missing values generate warnings. `.dev.vars*`, `.env*`, `wrangler.toml`, and all `.p8` files are excluded by `.gitignore`.

## 5. Validate and deploy

Run repository tests and syntax checks first:

```sh
npm test
npm run check
npx wrangler deploy --dry-run
```

Confirm that the Worker name, KV ID, Durable Object bindings, and route in the output all belong to the intended environment, then deploy:

```sh
npm run deploy
```

Verify:

```sh
curl --fail --show-error https://airsim-push.remotepilot.site/healthz
```

Expected response resembles:

```json
{"ok":true,"service":"airsim-push-relay","version":"0.2.1"}
```

The Dashboard is at `/dashboard`. Its API uses a Bearer token:

```sh
curl --fail --show-error \
  -H "Authorization: Bearer ${AIRSIM_DASHBOARD_TOKEN}" \
  https://airsim-push.remotepilot.site/dashboard/api/summary
```

Do not expose real tokens in shell history, screenshots, or tickets.

## 6. Configure the iOS app

The main app's `Info.plist` reads these build settings:

- `AIRSIM_PUSH_RELAY_URL`: for example `https://airsim-push.remotepilot.site`, without a trailing path.
- `AIRSIM_APNS_ENVIRONMENT`: `sandbox` for Debug; `production` for Release/TestFlight.
- `APS_ENVIRONMENT`: `development` for Debug; `production` for Release; must match the signing profile.

Set them in the target's Xcode Build Settings or override them in an automated build:

```sh
xcodebuild \
  -project iOS/AirSIM.xcodeproj \
  -scheme AirSIM \
  -configuration Debug \
  AIRSIM_PUSH_RELAY_URL=https://airsim-push.remotepilot.site \
  AIRSIM_APNS_ENVIRONMENT=sandbox \
  APS_ENVIRONMENT=development
```

For a release, use `Release`, `production`, and distribution signing. Never ask users to enter `.p8` in the app; the APNs private key belongs only on the Relay.

## 7. Automatic device registration

Wrangler deploys the Worker, binds KV/DO, and configures domains and Secrets. **It does not generate or populate per-device APNs tokens.** Signed apps register themselves:

1. At first launch, the app registers PushKit and separately requests normal notification permission. The system returns separate VoIP and regular APNs tokens; Watch and Live Activity tokens may be added later.
2. The app generates and stores its own `device_id` and `device_secret`. Temporarily set `NEW_DEVICE_ENROLLMENT_ENABLED = "true"` and deploy only while adding a new paired device. New IDs are closed by default and limited to eight enrollments per hour while open.
3. It submits tokens, Bundle ID, APNs environment, Relay URL, and media capabilities to `POST /v1/devices/register`, and synchronizes them with the paired Agent.
4. The Relay validates Bundle ID, token format, and environment, storing a hash of `device_secret`, not its plaintext. `STATUS` Durable Object is authoritative; KV is a mirror/fallback.
5. Later registrations for the same `device_id` must use the same Secret. The app re-registers automatically on system changes or APNs token rotation even when new enrollment is closed. Once the new device appears, set `NEW_DEVICE_ENROLLMENT_ENABLED = "false"` and redeploy.

To add a device: install the signed app → set Relay URL → pair with the Agent → enable cloud mode/notifications → keep the app foregrounded once until registration succeeds. Do not maintain a device list in Wrangler configuration or manually populate KV.

Only in a diagnostic test environment with new enrollment enabled, use placeholders to inspect the API shape:

```sh
curl --fail-with-body \
  -H 'Content-Type: application/json' \
  -d '{
    "device_id":"test-device-01",
    "device_secret":"replace-with-at-least-16-random-characters",
    "voip_token":"00112233445566778899aabbccddeeff",
    "alert_token":"",
    "watch_voip_token":"",
    "live_activity_push_to_start_token":"",
    "bundle_id":"org.example.airsim",
    "environment":"sandbox",
    "media_transport":"webrtc"
  }' \
  https://airsim-push.remotepilot.site/v1/devices/register
```

Do not copy this sample Secret for production devices. Production Secrets should be randomly generated by the app and kept in Keychain.

## 8. Deployment acceptance

Run these separately with a Debug device build and a Release/TestFlight build:

1. `/healthz` succeeds; the Dashboard is readable with its token, while anonymous API access returns `401`.
2. Installed iPhone `aps-environment` matches `AIRSIM_APNS_ENVIRONMENT`.
3. App startup registers successfully and the Dashboard shows a registration event.
4. VoIP push produces CallKit incoming-call UI when the screen is locked, the app is backgrounded, and after system process reclamation.
5. Answer, reject, hang-up, and timeout events reach the Agent; duplicates do not create another call.
6. Validate ordinary notifications, Watch incoming calls, and Live Activity topics individually.
7. Agent disconnection, incorrect Secrets, expired commands, and failed media authentication are rejected.
8. Cloud media setup is permitted only with configured TURN, enabled rollout, a WebRTC-capable app, and a fresh revision-2 native-service heartbeat. Registration-only or historical capability claims do not authorize a call. Verify unavailable-media dial/answer rejection, incoming carrier-call preservation, and binary rejection for all roles.

## 9. Troubleshooting

| Symptom | First checks |
| --- | --- |
| `APNs credentials are incomplete` | Verify `APNS_TEAM_ID`, `APNS_KEY_ID`, and `APNS_P8` in the same environment |
| APNs `InvalidProviderToken` | Team ID/Key ID must match `.p8`; check Worker time and PEM contents |
| APNs `BadDeviceToken` | Check sandbox/production mismatch and token rotation |
| APNs `DeviceTokenNotForTopic` | Match Bundle ID, provisioning profile, and `.voip`/Watch/Live Activity topics |
| Registration `400` | At least one token, hexadecimal format, Bundle ID, Watch Bundle ID, and environment fields |
| Registration `401` | Same `device_id` used a different `device_secret`; do not overwrite production records directly |
| Dial/answer endpoint `409` | Inspect `remote_audio_reason`; missing/stale native readiness, unsupported media, disabled policy, and missing TURN/rollout fail closed. Incoming carrier calls instead remain on Android with an unavailable-audio mirror when an alert token exists. |
| Dashboard `503` | `DASHBOARD_TOKEN` is not configured |
| `Exceeded allowed volume of requests in Durable Objects free tier` | The account exhausted its daily Durable Objects request allowance. Inspect usage by `STATUS`, `COMMANDS`, and `MEDIA`. `/commands/connect` is the failing entry point, not necessarily the main source of usage. The documented free allowance resets at 00:00 UTC (08:00 China time); investigate frequent polling/reconnects after recovery. |
| Custom-domain deployment fails | Check conflicting CNAME/Worker routes and whether the zone belongs to the current account |

Redact sensitive data when viewing live logs:

```sh
npx wrangler tail
```

Logs must not contain `.p8`, complete APNs tokens, device secrets, complete phone numbers, or media content.

## 10. Security and rollback

- Manage Secrets only through Wrangler Secrets/CI Secrets. Suspected leaks require prompt Apple/Cloudflare rotation and revocation of old values.
- Keep Dashboard tokens separate from device secrets; devices cannot call Dashboard administration APIs.
- The Worker stores only device-secret hashes. Media connections also validate call UUID, role, generation, and per-call secret.
- This implementation limits APNs payloads to 4096 bytes.
- Retain the previous Worker version before release. Prefer version rollback during failure; do not delete KV namespaces or Durable Object migrations.
- Worker, Agent, and iOS/watchOS JSON/media protocol changes must remain compatible with older clients or ship together.

## 11. AI-assisted deployment

Adjacent `codex.md`, `claude.md`, and `LLM.txt` provide repository facts, safety boundaries, and acceptance order for deployment assistants. They do not replace the operator's Apple/Cloudflare access and must not contain real credentials.

## 12. Official references

- Apple: [Communicate with APNs using authentication tokens](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens), [Register your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns), [Respond to PushKit VoIP notifications](https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit), [Make and receive VoIP calls with CallKit](https://developer.apple.com/documentation/callkit/making-and-receiving-voip-calls).
- Cloudflare: [Wrangler configuration](https://developers.cloudflare.com/workers/wrangler/configuration/), [Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/), [Worker Secrets](https://developers.cloudflare.com/workers/configuration/secrets/), [Create a KV namespace](https://developers.cloudflare.com/kv/get-started/), [Durable Object migrations](https://developers.cloudflare.com/durable-objects/reference/durable-objects-migrations/).

### Native WebRTC calls and current readiness

The Relay is a control/signaling service. Real call media is native WebRTC/Opus
between Android and iPhone, optionally relayed by TURN, never binary audio over
Worker WebSockets. `MEDIA`, `STATUS`, `COMMANDS`, KV registration, and the deployed
Durable Object migrations retain their existing identities.

Cloud setup requires all of:

- `WEBRTC_TRANSPORT_READY=true`, a rollout bucket that includes the device, and
  valid TURN configuration.
- App `media_transport: "webrtc"` and `app_media_capabilities: ["webrtc"]`.
- The **latest authenticated Agent heartbeat**, received within 90 seconds,
  contains `media_capability_revision: 2`, `agent_media_ready: true`, and
  `agent_media_capabilities: ["webrtc"]`.
- No explicit `remote_audio_disabled` policy.

Revision 2 describes the Android-owned native media service. `agent_media_ready`
means that service has initialized and its native SDK is available. It does not
mean that carrier audio has connected: session `webrtc_ready` remains the
stronger requirement of peer connectivity plus a verified live telephony route.
There is no phone-model allowlist and no claimed physical-device acceptance.
Missing, unsupported, stale, or explicitly false heartbeat fields revoke setup
eligibility. An old ready entry in the Agent roster cannot override the latest
heartbeat. Registration fields and stored capability claims cannot establish or
restore readiness. If `STATUS` is configured, a failed authoritative heartbeat
read does not fall back to a possibly stale KV readiness mirror.

Registration still succeeds for control-only/older combinations and returns
`media_transport: null`. Pairing, device secrets, push tokens, SMS, and call
history remain intact. Native-service registration should be followed by a
current heartbeat before attempting remote calls.

Dial and remote answer return HTTP 409 with `remote_audio_available: false` and
a bounded `remote_audio_reason` instead of creating/dispatching a cellular action
with unsupported media. Queued dial/answer commands recheck readiness at initial
delivery, pull, reconnect, and retry. Duplicate dial commands retain their
original call UUID/secret rather than allocating a second media session; failed
or expired duplicates do not return a new call. Existing pre-migration queued media commands
without the new authenticated device metadata fail closed; reject/end and other
control commands retain their durable behavior. WebSocket answers also recheck
readiness before ownership or forwarding, including when flushing a queued
answer. Cancellation, terminal state, and socket replacement win a concurrent
readiness check.

For an incoming carrier call with unavailable remote media, Relay retains a
ringing lifecycle and returns HTTP 202 with `media_transport: null`,
`remote_audio_available: false`, and `remote_audio_reason`. It can send a normal
mirror alert instructing the user to answer on Android, but sends no answerable
VoIP/Watch/Live Activity presentation or media credentials. It never sends a
carrier hangup merely because remote audio is unavailable. Unsupported stored
calls cannot open a media WebSocket. Watch is companion control: direct
`owner: "watch"` answers are rejected with `iphone_audio_required`; the companion
must ask iPhone to perform the answer and own the native peer. Reject/end control
and existing owner isolation are preserved.

Old `force_legacy_pcm: true` records migrate on registration to
`remote_audio_disabled: true`, never to another transport. The obsolete field is
not written back. An old `force_legacy_pcm: false` or stale Agent registration
cannot re-enable calls; the app must explicitly set `remote_audio_disabled: false`.
Saved identities and pairing are not cleared. Registration by an Agent cannot
overwrite the paired app's existing transport/capability/disabled policy.

Configure `TURN_URLS` as a JSON array of `turn:`/`turns:` URLs (optional
`?transport=udp|tcp`), and store coturn's shared REST secret as the Worker secret
`TURN_SHARED_SECRET`. Optional `STUN_URLS` is a JSON array of `stun:`/`stuns:` URLs.
No public STUN/TURN service is hardcoded. Set `TURN_TTL_SECONDS` to a lifetime in
seconds (default 3600, minimum 60, maximum 86400 / 24 hours, and shortened
to the call's expiry). The 86400-second maximum applies to both TURN providers.
The TURN service must independently enable its matching REST authentication
secret. This repository does not provision, deploy, or validate reachability of
a TURN service.

`GET /v1/calls/:uuid/ice?role=iphone|agent` requires `Authorization: Bearer
<call_secret>`. It returns `ice_servers` and `ttl`, with `Cache-Control: no-store`
on successes and failures. TURN credentials use the standard coturn REST
`expiry:call_uuid:role` username and base64 HMAC-SHA1 password. No TURN secret,
credential, or SDP is logged. Coturn credentials are generated on demand;
managed Cloudflare TURN credentials are cached server-side for the authenticated
call and role until they expire, with at most 12 issuance attempts per call role.
Missing TURN produces a 503 response and prevents rollout selection; a readiness flag alone is not
sufficient.

On the authenticated call WebSocket, the owning iPhone sends `webrtc_offer`, the
agent sends `webrtc_answer`, and both may send `webrtc_ice` after an offer. Every
WebRTC client authenticates the upgrade with `Authorization: Bearer <call_secret>`;
the URL contains only the media role. Query-string secrets are rejected for all
roles, even when a valid Bearer header is also present. The old
`WEBRTC_AGENT_QUERY_AUTH_ALLOWED` switch has been removed and cannot restore the
exception. ICE credential requests enforce the same bearer-only rule and reject
unsupported stored calls. Unsupported legacy-media calls are rejected, not
upgraded in place. Keep automatic Worker invocation logs disabled because even
rejected old clients can put credentials in request URLs; explicit redacted
application logs can remain enabled. Every signaling message includes `call_uuid`, integer
`generation`, and UUID `session_id`. SDP is
limited to 48 KiB, ICE candidate strings to 4096 characters, and frames to 64 KiB.
Only negotiation identities are kept in hibernation attachments. Relay never
queues SDP or candidates: clients queue at most 128 ICE candidates until remote
SDP is installed. After `peer_connected`, start a fresh negotiation; old
connection callbacks and mismatched session IDs are rejected. Repeated offers
cannot reuse a session ID. At most 24 negotiations are retained per connected
pair to fit Durable Object attachment limits; both peers must reconnect after
that limit. Binary frames are rejected for every role and transport; there is no Watch or
legacy PCM path. Durable answer/end receipts remain control-plane messages.
New hibernation attachments use `connectionKey`; the old `pcmTraceKey` is read
only as a bounded identity alias for already-hibernating sockets, never audio.

Local validation: `npm run check && npm test`. The tests cover credential HMAC,
authentication/expiry, configuration gates, signaling identity/roles/bounds,
reconnect, owner isolation, unavailable-media preflight and revocation, current
heartbeat semantics, disabled-policy migration, carrier-call preservation, and
negative legacy/Watch audio behavior. They do not establish
TURN reachability, native device audio quality, or production readiness.

For managed Cloudflare TURN, use `TURN_PROVIDER=cloudflare`,
`CLOUDFLARE_TURN_KEY_ID`, and Worker secret `CLOUDFLARE_TURN_API_TOKEN` instead
of coturn's URL/shared secret. Relay requests short-lived ICE servers from
Cloudflare's TURN credential endpoint with a five-second timeout, validates
that the response contains authenticated TURN servers, and returns the same
client `ice_servers`/`ttl` format. Optional `STUN_URLS` can supplement either
provider. Provider failures return a generic 503 without exposing response
bodies or credentials. Local tests mock this provider; no TURN key creation,
external credential request, deployment, or reachability test is performed.
