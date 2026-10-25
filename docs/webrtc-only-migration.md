# WebRTC-only privileged-media migration: draft validation gate

This branch is a buildable migration prototype, not a validated release or a deployment.
The existing Q25 and Pixel 8 Pro verification applies to the previous architecture;
**neither device has yet validated the new privileged native peer**. Do not infer
physical two-way carrier audio from a passing build, native tone test, RTP count,
accepted SDP, or service-ready heartbeat.

## Current architecture

- Android Standalone owns Telecom, SMS, pairing, authenticated local/cloud signaling,
  call identity, and ephemeral ICE credential retrieval.
- One Shizuku shell/root service owns the native WebRTC/Opus peer and carrier capture /
  injection in the same process. No audio bytes cross Binder, pipes, TCP, WebSocket,
  or DataChannel. The application process is a signaling proxy only.
- The pinned SDK stays at 144.7559.15. Its external audio callbacks exchange bounded,
  in-process 8 kHz mono samples with VOICE_DOWNLINK and the telephony uplink device.
  This is an OS/audio-device boundary, not a competing media transport or jitter engine.
- iPhone uses native WebRTC for cloud and host-only local calls. Watch is an iPhone
  companion controller, not an independent microphone/speaker endpoint.
- AVF remains available for pairing, SMS, call state and terminal controls. It returns
  upgrade_required for dial/answer/audio setup; it does not advertise a native peer.
- The Worker relays authenticated signaling/control, not audio. TURN is separate.

## Readiness is not one boolean

1. A revision-2 authenticated heartbeat younger than 90 seconds can report the current
   native service as available. Stored registration capabilities never authorize a dial.
2. A session becomes ready only when its native peer is connected and carrier capture
   is running with a verified uplink route. A returned SDP answer is not readiness.
3. A physical two-way carrier-call acceptance result is a separate, unperformed gate.

The initial adapter requires an observed TYPE_TELEPHONY sink. It still detects the
Samsung VOICE_TX capability, but accepting a vendor tag alone does not prove routing.
A device with a legitimate hidden OEM route may therefore fail closed. This is an
**unresolved compatibility gate**, not proof that the device is unsupported. Implement
and validate an appropriate vendor route-evidence mechanism before claiming Q25
acceptance. The implementation has no device-name allowlist or speaker/mic fallback.

When media is unavailable, Relay rejects new outgoing dial and remote answer before
queuing a cellular action. An existing incoming carrier call remains ringing on
Android; a normal informational alert may say to answer there. Watch cannot acquire
cloud media ownership. A kill switch disables new calls; it cannot select PCM.

## Privileged control contract

Privileged IPC version 2 accepts only prepare/start/signal/poll/stop. Each request and
response has a positive request_id, with exact call_uuid / generation and random
owner_id on session operations. One owner may have a live peer. A new owner can
reconnect the same call only after the old peer is disposed; old owner tombstones
reject resurrection. Queues retain at most 64 events and responses return one bounded
event, preserving the 96 KiB UTF-8 frame cap. SDP is capped at 48 KiB characters and
ICE candidates at 4096 characters. Overflow is terminal, never a raw-audio fallback.

Binder checks the caller's actual UID against the installed APK UID and links an
owner Binder to death. The fallback process accepts commands only through inherited
pipes, not a listening socket, and exits on EOF. Both paths use the same service,
identities, size bounds and asynchronously queued events. Polling delivers those
asynchronous events without transporting samples. An owner that stops polling loses
its peer after 30 seconds. Closing reports inactive immediately but retains ownership
until the signaling executor has joined carrier workers and released the native peer,
tracks, factory and audio module. Local output is restored before another owner or
Binder service can start. Cleanup failure or a worker join timeout keeps the service
occupied/unavailable until the privileged process restarts; it never assumes disposal
succeeded. No Binder/UI caller waits for native teardown. Closing/quarantined peers
report unavailable in live admission status and prepare responses, but the owner can
still poll terminal events and repeat stop. Healthy active owners remain ready. Agent
heartbeats use one fresh status response for both readiness and capability fields,
never the cached UI status.

Only session-scoped ICE configuration enters the privileged service. Account bearer
secrets remain in the ordinary APK. Native libraries load from the installed signed
APK's native library directory, not a downloaded path. The service is non-daemon;
SDK Android network monitoring is disabled because app_process is not a normal
Application. Native ICE sockets remain enabled. Network transitions and native loading
in both UserService and pipe launch routes still require actual device validation.

Moving native SDP/RTP/codec parsing into shell/root increases attack exposure. This
branch does not establish that the resulting privilege boundary is adequate for a
production release. Review the smallest workable identity, OEM SELinux behavior,
parser exposure, malformed input, owner loss, teardown and APK upgrade before rollout.
No security-policy weakening, generic command runner, credential creation, device
installation, real calls, or deployment is part of these source changes.

## Local iPhone status and cancellation

HMAC-authenticated POST /api/calls/webrtc offers keep their existing identity format.
POST /api/calls/webrtc/status and /api/calls/webrtc/stop require
{version:1, call_uuid, generation, session_id}. Status echoes that exact identity and
returns preparing, ready, failed or closed with a generic reason. Stop is idempotent
and tombstones even a not-yet-arrived offer. A stale stop cannot close another session.
iPhone polls with a bounded startup timeout and fences callbacks by all identities.
CallKit activation governs both local and cloud peers. Recording uses the current call
UUID rather than a transport label; existing protected local files are preserved.

## Legacy boundary and remaining deletion gate

The production APK no longer compiles or launches android/phone-audio-bridge. No
AIRSIMPCM1 handshake is present in its DEX. The legacy source directory remains only
as a reference for the physical architecture gate; its standalone scripts are not
part of the supported build/run workflow. Do not launch them alongside the new service.
Its complete removal is deferred until Q25/Pixel route and teardown acceptance.
Package-scoped old-daemon eviction still recognizes the historical class/port so an
upgrade can stop a stale bridge without killing unrelated processes.

Old policy values are accepted only for safe migration/rejection, not fallback. Relay
requires bearer headers and keeps deployed Durable Object bindings/migration history.
Existing pairings, identities, ordinary registration, SMS and recordings are not reset.
Historical release notes describe their original versions and have not been rewritten.

## Validation to perform before release

- Cloud: JVM protocol/readiness/owner/negative-transport tests; APK build, API-29 bytecode
  guard, all four native ABIs, 16 KiB alignment and signature verification; Relay and
  Go suites. Delayed/failed-disposal tests cover the real service retirement gate and
  the production peer's executor cleanup with synthetic resource boundaries. They do
  not exercise native JNI disposal or an actual privileged carrier route.
- Mac: Xcode iOS/Watch builds and tests, native simulator recording/lifecycle tests,
  Android native emulator tests when available. An emulator cannot validate carrier audio.
- Separately authorized physical acceptance on both reference phones: shell/root launch,
  signed APK native loading, actual two-way carrier speech, direct local ICE, forced TURN,
  phone lock/background, interruption, route/mute changes, repeated calls, service/app
  death, Shizuku restart, APK upgrade, output-volume restoration and leak checks.
- Inspect sockets/processes: no AirSIM 7580/7593 listener; remote media is Opus RTP
  protected by DTLS-SRTP, never binary WebSocket/DataChannel sample traffic.
- Record startup latency, underruns, CPU and sustained backlog against the old baseline.
  The NetEq 50-packet cap alone is not a mouth-to-ear latency measurement.

Keep this change in draft until these boundaries are reviewed. Deployment and release
require their own authorization and compatible client/Relay versions.
