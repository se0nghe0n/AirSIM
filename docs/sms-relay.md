# Incoming SMS relay (Android → Relay → iPhone)

Status: implemented on `fix/sms-relay` (2026-11-10). Physical-device acceptance is still required; see
[Device acceptance](#device-acceptance).

## Why no SMS arrived

The SMS path was never removed. Capture, the durable queue, the Relay endpoint and the iPhone
notification all exist. Received messages were captured and stored on Android, but **never sent to
the Relay**, because the cloud sender put SMS behind call events in one all-or-nothing flush.

| Hypothesis | Finding |
| --- | --- |
| SMS capture missing on Android | **No.** `IncomingSMSReceiver` (`SMS_RECEIVED`, guarded by `BROADCAST_SMS`) and `RECEIVE_SMS`/`READ_SMS` are declared in `android-standalone/AndroidManifest.xml`. On the attached Pixel 8 Pro (Android 17, package `com.airsim.phonecontrol.pixel8pro`, versionCode 83), `dumpsys package` shows the receiver registered and both permissions granted. |
| Dropped in the WebRTC-only / Standalone migration | **No.** `51f25d3` (remove legacy AVF and USB runtime paths) deleted the AVF branch from `IncomingSMSReceiver` and `SMSInboxScanner` and kept `StandaloneAgentGateway.sendSMSEvent`. `90c0692` (privileged native WebRTC) only added `extractNativeLibs`. `docs/webrtc-implementation-contract.md` keeps SMS unchanged. |
| Never sent over the channel | **Yes. This is the root cause.** See below. |
| Not shown on iOS | Not the cause. `AirSIMAppDelegate` presents `incoming_sms` alert pushes and saves them to history. One gap remained: a truncated push was never saved (fixed below). |

### Root cause: head-of-line blocking in the Agent's event flush

`StandaloneAgentService.flushEvents()` on `main`
(`android/phone-control-app/src/com/airsim/phonecontrol/StandaloneAgentService.java:302-320`):

1. It sends every queued call event first. It removes an event (`CALL_EVENTS.poll()`, line 307) only after the Relay accepts it.
2. Only after that does it send pending SMS to `POST /v1/events/sms` (line 317).
3. Any exception aborts the whole cycle (`standalone_agent_cycle_failed`, line 131), and the next cycle starts again at the same head event.

The Relay permanently refuses a terminal call state for a call whose record no longer exists.
`receiveCallState` (`push-relay-worker/src/index.mjs:1936-1944` on `main`) returns
`409 {"reason":"call_identity_mismatch"}` when the `call:<uuid>` record has expired after its 5 h
TTL, was never written, or has another generation. The Agent's repair path only recognises
`reason: "identity_mismatch"` with a lifecycle snapshot (`StandaloneCloudMediaManager.java:200`), so
`CallLifecycleConflict.decide` returned `RETHROW` (`:162`). The `ended` event therefore stayed at the
head of the queue forever. Every SMS behind it, and every later call event (including future
incoming-call pushes), was blocked. Because `closeActive` (`:144`) ran only after a successful
publish, the stale call's media WebSocket also kept reconnecting with `401` about every 1.2 s.

Evidence from the attached phone, read-only through `adb logcat -s AirSIMBridge` on 2026-11-10 at 14:03 KST.
The Agent process had been up for 24 h:

```
E/AirSIMBridge: standalone_agent_cycle_failed failures=3148 error=RelayHTTPException detail=Relay HTTP 409: {"accepted":false,"reason":"call_identity_mismatch"}
E/AirSIMBridge: standalone_cloud_media_disconnected error=RelayHTTPException detail=Relay HTTP 401: WebSocket handshake failed: HTTP/1.1 401 Unauthorized
```

At about 15 s per cycle, 3,148 consecutive failures means the queue had been wedged for about 13 h,
since about 00:50 KST. The SMS inbox recorded 3 messages after that time (05:00 and 08:00 KST) and
1 MMS (13:00 KST). Nothing reached the Relay during that time.

The receiver stores SMS independently of the flush, so the 3 SMS should be waiting in `standalone_sms`
with `cloud_sent=false`. This could not be read directly, because the release build's private store is
not accessible. The MMS was never captured at all (see below). The retained `AirSIMBridge` log covered
only the last 15 minutes, filled by the 401 retries. Only message counts and times were read; no
bodies or numbers.

Any other permanent refusal had the same effect. Examples: a `409 alert token unavailable` for SMS
when the iPhone has no notification token, or a `502` for an SMS that could never fit in an APNs
payload. Each blocked the queue indefinitely.

### Contributing gaps

- **MMS/LMS never relayed.** Only `SMS_RECEIVED` and `Telephony.Sms.Inbox` were read. Korean
  carriers deliver messages over 90 bytes as LMS, which are MMS. Only the default SMS app downloads
  them, and they never produce `SMS_RECEIVED`.
- **Long Korean text could not be pushed.** The Relay put up to 700 code points in both
  `aps.alert.body` and `content`. For Hangul that is more than 4 KB, and `sendAPNs` throws
  `APNs payload too large`. The Relay returned 502, and the Agent retried that message forever.
- **Truncated pushes were not kept on iPhone.** `AirSIMAppDelegate.persistRemoteSMS` returned early
  for `content_truncated` while it waited for a local VoWLAN sync, which cloud-only use never
  performs.

## Design

The architecture is unchanged. Received messages are stored durably on Android and sent through the
existing authenticated Relay endpoint `POST /v1/events/sms`. The Relay sends them as an APNs
**alert** push (`event: incoming_sms`). On the hotspot, the existing VoWLAN routes `/api/events`,
`/api/sms` and `/api/sms/ack` still deliver them. No new wire contract, Relay route or storage
location is added.

The Relay stores no SMS bodies. It keeps only a 7-day `dedupe:sms:<device>:<delivery_id>` marker.

The WebRTC DataChannel and PushKit VoIP are not used for SMS. A DataChannel exists only during a
call, and PushKit is reserved for CallKit calls (`iOS/README.md`).

```
carrier SMS ──SMS_RECEIVED──▶ IncomingSMSReceiver ┐
SMS/MMS provider (READ_SMS) ─▶ SMSInboxScanner ───┴▶ StandaloneSMSStore (durable, deduped)
                                                     │                │
                       SMS lane (own thread, wakes   │                └▶ VoWLAN /api/sms → iPhone (local)
                       on receive / provider change) ▼
                         POST /v1/events/sms ──▶ Relay ──APNs alert──▶ iPhone notification + history
```

### Android (`android/phone-control-app`)

- **Separate SMS lane.** `StandaloneAgentService.smsLoop` runs on its own worker thread. It sends
  pending messages oldest-first and starts immediately when
  `StandaloneAgentGateway.sendSMSEvent` → `requestSMSDelivery` signals it. Call events, heartbeats,
  command polling and their back-off can no longer delay or block it. The lane also runs the inbox
  fallback, which was previously tied to the 2 s Relay loop.
- **Per-message classification** (`SMSRelayPolicy`):

  | Relay response | Action |
  | --- | --- |
  | 2xx (including `duplicate`) | `markCloudSent` |
  | 400, 413, 422 | `markCloudRejected`. The message leaves the cloud queue and is kept for local delivery, with diagnostic flag `cloud_rejected`. |
  | 0 (network), 401/403, 404, 408, 409 (no iPhone alert token), 429 | Keep the message and end the pass, because these failures affect every message. |
  | 5xx | Keep the message and continue with the next one, because an APNs refusal can be specific to one message. The pass ends after 3 consecutive 5xx. |

  After a failed pass the lane retries after 5 s, 10 s, 20 s and so on, up to 5 min. A newly
  received SMS triggers one attempt immediately. The lane never discards a message for a
  configuration problem such as credentials, an older Relay or a missing token.
- **Event contents that stay deliverable.**
  - The cloud copy of the text is capped at 1,700 UTF-8 bytes (`SMSRelayPolicy.cloudContent`), cut
    on a character boundary and marked with `…`. The Relay places the text in the push twice, so
    long Hangul still fits in APNs' 4 KB, even on a Relay without the change below.
  - A carrier timestamp ahead of the phone is sent as "now" (`cloudTimestamp`), so the Relay's
    5-minute future check cannot reject it. The `delivery_id` keeps the original time.
  - The local store keeps the full text and the original time.
- **Call-event queue cannot wedge** (`flushCallEvents`).
  - An event the Relay keeps refusing with a 4xx is logged as `cloud_call_event_dropped` and
    removed once it has been refused for 30 s. This covers every 4xx except 401/403/404/408/429
    (`CallLifecycleConflict.permanentRejection` / `dropRejectedEvent`). Each retry carries a fresh
    timestamp, so the grace period still lets a `stale_timestamp` caused by clock skew succeed.
  - A malformed event is dropped at once. Transient failures keep strict order.
  - A terminal state answered with `409 call_identity_mismatch` is recognised as obsolete
    (`CallLifecycleConflict.obsoleteTerminal`) and completes at once.
  - A permanently refused `ended` still releases the local cloud session. This stops the 401
    reconnect loop.
  - A retried incoming-call announcement reuses its call identity
    (`StandaloneCloudMediaManager.unannounced`). The Relay may already hold that call's ringing
    state (written before APNs); a new identity would be refused as `identity_mismatch` and leave
    that state open. If the call ends unconfirmed, that identity is still ended.
- **MMS/LMS text** (`SMSInboxScanner.scanMMS`, `MMSInboxPolicy`). With the optional `READ_SMS`, the
  lane reads `content://mms/inbox` messages that the default SMS app has downloaded. It joins their
  `text/plain` parts, decodes part charsets including EUC-KR and UTF-8, and takes the `FROM` (137)
  address. The result is queued like an SMS.
  - It uses its own cursor, `last_mms_inbox_id`. The first authorized scan sets a baseline over all
    MMS boxes, so earlier messages are never imported. This includes messages received before an
    upgrade.
  - A not-yet-downloaded notification row holds the cursor for up to 10 min. A downloaded row
    without readable text holds it for 60 s in case its parts are still being written. Both waits
    count from when the scanner first saw the row, not from the MMSC date. While a row waits, the
    scanner looks again every 5 s.
  - A row whose text cannot be read is treated as having no text, so it cannot stall later MMS.
  - Images and other attachments are not relayed.
- **Faster fallback.** A `ContentObserver` on `content://mms-sms/` wakes the lane, rate-limited to
  one scan per 2 s. A throttled wake schedules a trailing scan instead of being lost. The observer
  is registered once Read SMS is granted. Without it the scan runs every 30 s.
- **Diagnostics without message data.** The "SMS relay" card on the Android Settings tab shows how many
  messages are waiting and the last Relay error, for example "iPhone notification token is not
  registered (HTTP 409)". `/api/sms/status` adds the additive fields `cloud_pending` and
  `cloud_last_error`. Logs contain only delivery IDs and status codes.

### Relay (`push-relay-worker`)

`fitIncomingSMSPayload` shortens the text, still capped at 700 code points and marked with `…` and
`content_truncated: true`, until the whole JSON payload is at most 4,000 bytes. The sender shown in
the push is capped at 64 characters, because MMS senders can be e-mail-style addresses. The
authentication, dedupe, `409 alert token unavailable` and wire format are unchanged. This protects
any Agent version, not only this one.

### iOS

A truncated push is saved as a preview (`SMSHistoryPolicy.insertingRemote`), so long messages appear
in Messages in cloud-only use. A later local VoWLAN sync replaces the preview with the full body
because it has the same `delivery_id`. A duplicate push does nothing.

### Data preservation

The package, signing identity and preference files are unchanged. All changes are additive:

- the `cloud_rejected` flag on `standalone_sms` records
- the `last_mms_inbox_id` key in `sms_inbox_fallback`

The persistence suite reopens pre-upgrade records and checks rejection, local acknowledgement and
tombstones. Upgrading in place keeps pending SMS. Messages stuck today should be sent on the first
lane cycle after the upgrade, because the in-memory call-event queue starts empty after the restart.

## Platform and policy constraints

- **Permissions.** `RECEIVE_SMS` (broadcast) and `READ_SMS` (inbox fallback and MMS/LMS) are
  hard-restricted runtime permissions. An `adb install` exempts them
  (`RESTRICTION_INSTALLER_EXEMPT` on the test phone). An APK opened from a browser or file manager
  can show "Restricted setting" on Android 13 and later. The user must then allow restricted settings
  in App info before granting SMS access. AirSIM does not request `RECEIVE_MMS` or
  `RECEIVE_WAP_PUSH` and never downloads MMS itself.
- **Default SMS handler.** Not requested and not needed. AirSIM holds `ROLE_DIALER`, and Google
  Messages stays the SMS role holder that writes the provider. Taking the SMS role would make AirSIM
  responsible for storing, downloading and sending every message.
- **RCS.** RCS (chat) messages live in Google Messages' private storage and are not readable by
  other apps. Only carrier SMS and MMS are relayed.
- **Android 17 OTP protection.** The SMS Retriever and WebOTP formats are withheld from AirSIM for
  3 h on every target SDK: both the broadcast and the provider rows are hidden. When targetSdk is
  37 or higher, ordinary SMS that contain an OTP are also withheld for 3 h. The manifest targets 35.
  Raising `targetSdkVersion` to 37 would delay most verification codes by 3 h, so keep it at 35 and
  review this before raising it. Exempt are the default SMS app and "connected device companion"
  apps (CompanionDeviceManager associations); a CDM association would need separate design.
  See [Android 17 behavior changes](https://developer.android.com/about/versions/17/behavior-changes-all)
  and [targeting 17](https://developer.android.com/about/versions/17/behavior-changes-17).
- **Google Play.** The [SMS and Call Log policy](https://support.google.com/googleplay/android-developer/answer/10208820)
  allows `RECEIVE_SMS`/`READ_SMS` only for the default SMS or Assistant handler, or under a listed
  exception. Being the default Phone handler covers only `SEND_SMS` and the call-log permissions. A
  Play build would need the Permissions Declaration Form with the exception "Cross-device
  synchronization or transfer of SMS or calls", or "Connected device companion apps". That
  exception covers `READ_SMS`, `RECEIVE_SMS`, `RECEIVE_MMS`, `RECEIVE_WAP_PUSH` and `SEND_SMS`, and
  approval is subject to Google review. AirSIM is currently distributed as a signed APK outside
  Play, so this is not yet a blocker.

## Builds: `android` vs `android-standalone`

`android/phone-control-app` holds the only Android source. `android/phone-control-app/build.sh`
defaults to `android-standalone/AndroidManifest.xml`, and `android-standalone/build.sh` calls the
same script with that manifest. Both outputs therefore get this change identically. The manifest
needs no change: `RECEIVE_SMS`, `READ_SMS` and the receiver were already declared. The separate
legacy AVF manifest `android/phone-control-app/AndroidManifest.xml` was removed in `51f25d3`. A
custom `AIRSIM_ANDROID_MANIFEST` must keep the receiver and both SMS permissions;
`android-standalone/test.sh` asserts them.

## Rollout

1. **Android APK (required).** This fixes SMS delivery and the wedged call-event queue, and works
   with the deployed Relay: the Agent already caps the text so long Korean messages fit. Sign the
   APK with the existing identity and install it in place; never uninstall it.
2. **Relay (recommended hardening).** Deploy with the usual dry-run first. This bounds the payload
   and sender for any Agent.
3. **iOS (optional).** Keeps truncated previews in history.

## Device acceptance

Android (Pixel 8 Pro, Android 17):

1. Install the signed release over the existing app. Open AirSIM → Settings and check the "SMS relay" card.
   Any stuck messages should drain, and the card should read "Relay delivery ready".
2. With the iPhone **off** the hotspot (cloud mode), send a short SMS to the Android number from a
   third phone. `adb logcat -s AirSIMBridge` should show `incoming_sms_queued`, then
   `cloud_sms_delivered`, within a few seconds.
3. Send an SMS longer than 90 bytes in Korean (delivered as LMS/MMS) with Read SMS granted. Expect
   `mms_inbox_scan … queued=1` and `cloud_sms_delivered`.
4. Turn iPhone notifications off or remove its token, and send an SMS. The card should show the 409
   hint. Calls must keep working, and the SMS should be delivered once the token is back.
5. Run one cloud call and hang up. There should be no `standalone_agent_cycle_failed` loop and no
   repeating `standalone_cloud_media_disconnected … 401`.

iPhone:

1. Cloud mode, app in foreground, background, locked and force-quit: each SMS shows a banner or lock
   screen alert titled with the sender. Tapping it opens that conversation.
2. The message appears in Messages. A long message shows the `…` preview in cloud mode and the full
   body after the next VoWLAN sync on the hotspot.
3. On the hotspot (VoWLAN), new SMS appear without the Relay. Afterwards, the Android "SMS relay"
   card shows nothing stuck.

## Follow-ups (not in this change)

- Relay: a lifecycle snapshot can outlive its 5 h `call:<uuid>` record. A matching terminal event is
  then refused, and new calls conflict with `identity_mismatch` until the lifecycle key expires.
  Accept a terminal state that matches the snapshot even when the call record is gone.
- Agent: an `incoming_call` refused with `identity_mismatch`, because another call is stuck at the
  Relay, is now dropped after 30 s instead of wedging the queue. Ending the stuck Relay call first,
  as `publishLifecycle` does, would let that call ring.
- Agent: stop a cloud media session after repeated `401` handshakes, independent of the call event.
