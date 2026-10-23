# Claude: AirSIM Relay secure deployment guide

Before assisting with deployment, read `README.md`, `wrangler.example.toml`, `package.json`, `src/index.mjs`, `src/status-store.mjs`, and `src/dashboard.mjs`, in that order. The source is the source of truth for the interface. Do not substitute an old DJOneHub configuration, resources from another AirSIM environment, or remembered Wrangler behavior for that check.

The current compatibility baseline (2026-10-12) is Apps `v0.9.6`, AVF Agent `v0.4.6` (Debian `0.4.6-1`), and Relay protocol `0.2.1`. The maintainer address is `https://airsim-push.remotepilot.site`. `https://push.remotepilot.site` belongs only to DJOneHub.

AirSIM must use a Worker, KV, Durable Objects, Dashboard token, and hostname that are independent of DJOneHub. This project's maintainer uses `https://airsim-push.remotepilot.site`. AirSIM must not take over DJOneHub's `https://push.remotepilot.site`.

As of 2026-10-08, the maintainer deployment has verified `/healthz`, an anonymous Dashboard `401`, and a `200` with the correct Bearer token. At the time of that check, no AirSIM device was registered. That does not justify claiming that real APNs, Agent heartbeats, commands, or cloud PCM have been accepted.

## Required rules

1. First confirm the Cloudflare account and zone, the target hostname, the Apple Team ID and Key ID, the operator's own primary Bundle ID, and whether the environment is sandbox or production.
2. `com.example.airsim` is only a source-repository placeholder. The deployer must re-sign the primary app, Watch app, and Live Activity with their own Apple Developer Team, and must set the Relay `ALLOWED_BUNDLE_ID` to match.
3. The app signing certificate and profile are a different set of credentials from the Relay APNs `.p8`. CallKit has no separate server certificate.
4. `APNS_P8` and `DASHBOARD_TOKEN` are required Worker Secrets. `[secrets].required` declares names only. Never write real values into TOML or `[vars]`.
5. `DASHBOARD_TOKEN` is the AirSIM Dashboard Bearer token. It is separate from a Cloudflare API token.
6. Do not request or display a `.p8`, Dashboard token, Cloudflare API token, device Secret, or APNs token. Have the operator enter them at a local prompt or in the CI Secret Store.
7. Create an independent `DEVICES` KV for each environment. Keep the `MEDIA`, `STATUS`, and `COMMANDS` bindings and every migration tag.
8. A hostname that is already live must get a read-only check of DNS, Custom Domain, and route first. Do not overwrite it directly.
9. Wrangler does not register an individual device. The signed app self-registers through `/v1/devices/register`. Static device tables and hand-written KV are prohibited.
10. `wrangler secret put` creates and immediately deploys a new version. Treat it as a production change.

## Recommended flow

```sh
cd push-relay-worker
npm ci
npm test
npm run check
npx wrangler whoami
cp wrangler.example.toml wrangler.toml
```

After authorization to create resources:

```sh
npx wrangler kv namespace create DEVICES
npx wrangler deploy --dry-run --config wrangler.toml
```

Confirm that `wrangler.toml` no longer contains `REPLACE_WITH_`, `com.example.airsim`, or a wrong domain. Add Secrets interactively:

```sh
npx wrangler secret put APNS_P8 --config wrangler.toml
npx wrangler secret put DASHBOARD_TOKEN --config wrangler.toml
npx wrangler secret list --config wrangler.toml
```

For a first deploy or CI, both values may go into a protected, Git-ignored temporary `.env.production`, then be uploaded atomically:

```sh
npx wrangler deploy \
  --config wrangler.toml \
  --secrets-file .env.production
```

When using `--secrets-file`, the Secret Store must create the file dynamically. Destroy it when the job ends, and do not let it enter a cache. A gradual deploy uses `wrangler versions secret put` and versions deploy.

Run the real deployment only after the operator has checked the dry-run and explicitly asked to go live. Then check `/healthz`, Dashboard Bearer authentication, automatic app registration, and a real sandbox or production PushKit → CallKit incoming call. The report must list unverified items. A successful Worker deployment is not the same as a successful push to a real device.

On failure, roll back the Worker version first and keep KV and Durable Objects. Do not delete migrations, rebuild the device store, switch the APNs environment, or overwrite a domain in order to hide the error.
