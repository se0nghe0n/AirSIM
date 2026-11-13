# Cloud audio startup on iPhone

> Current branch migration: native WebRTC and carrier capture/injection share the privileged Android process. There is no supported PCM network/IPC fallback. The AVF runtime is retired; Watch is an iPhone audio companion. Legacy bridge source/build instructions below are historical reference, not the current APK workflow. Physical-route and privileged-security gates remain unverified. See [the migration contract](webrtc-only-migration.md).


The iPhone prepares the current call's TURN credentials and native WebRTC initialization while its control WebSocket connects. Incoming calls prepare only TURN credentials and native initialization after CallKit reports the ringing call; their socket still waits for explicit acceptance. Outgoing calls begin after the Relay accepts the dial. Android also prefetches call-scoped credentials. Outgoing calls can then negotiate WebRTC during dialing/ringback, before the remote party answers. This requires matching iOS and Android builds; no Relay protocol deployment is required.

Credential prefetch alone does not create a peer or start audio. Outgoing `media_prepared` acknowledgement permits SDP and ICE after CallKit activation and microphone permission. The Android carrier device stays closed until Telecom reports active. Incoming calls retain successful answer confirmation as their peer/audio startup gate. Their ringing preparation opens no signaling socket, sends no answer or ownership claim, creates no peer, requests no microphone permission and opens no audio. Accepting the same call reuses its credentials; rejection, CallKit teardown, replacement, VoWLAN selection or 45 seconds without acceptance releases preparation. Call identity, generation, Relay endpoint and bearer credential must all match. A normal Relay socket may replace another socket for the same role, so incoming prewarm must not open one before acceptance. Current call identity and native/agent readiness checks still control usable audio. Codec, packet duration, jitter buffering, and playback behavior are unchanged.

TURN requests are shared only within the same call UUID, generation, Relay endpoint, and bearer credential. Hangup cancels preparation and discards credentials. A temporary audio interruption keeps the shared request available for the same call. Expired credentials are refreshed with a safety margin, and a failed prefetch can retry once when needed. Credentials remain in memory and are never included in diagnostics.

The iPhone trace event `ice_prepared` (category `cloud-call-audio`) includes `ice_wait_ms`: time still spent waiting for TURN configuration after the audio-start gates open. Near zero means the configuration was ready or completed immediately; this is not an end-to-end audio latency measurement. Comparing answer acknowledgement and `webrtc_ready` timestamps in the same call measures startup. That trace currently cannot be turned on or read in the app; see [Diagnostics](#diagnostics). Actual reduction requires a new external-network call; simulator tests do not establish carrier-call timing or quality.

Preparation tests cover request coalescing, expiration, transient and repeated failure, hangup, audio interruption, and credential/Relay rotation. Outgoing handshake tests also distinguish peer preparation from cellular answer, require a fresh reconnect acknowledgement, and keep recording unavailable until the call becomes active. Android tests cover deferred carrier activation, owner identity, reuse of the prepared peer, and cancellation before activation.

## Outgoing dial completion without an extra HTTP wait

The outgoing prewarm remains silent: it opens the signaling socket and prepares credentials, but does not claim ownership, create a peer, or open audio. Previously, adoption waited for the HTTP command-result poll and the socket's ping response. An already-running Android dial could therefore wait on those separate round trips before the iPhone sent the owner join that starts WebRTC.

After successfully executing the dial command, Android sends `outgoing_dial_accepted` on the call's media socket. It repeats this status when the iPhone connects later. This means exactly the same thing as the existing command result `completed` with `dialing: true`: the dial invocation succeeded. It does **not** mean that the remote party answered, the carrier route exists, or media is ready.

A matching iPhone races that status against the existing HTTP result. The status must contain the exact call ID, UUID and generation and arrive on the current outgoing prewarm connection. A valid received frame also proves that socket connected, so adoption need not wait for a redundant ping response. Missing, stale or foreign identities cannot finish either gate. HTTP remains the fallback with older Android builds or a lost signaling connection. Cancellation, replacement and expiry release the pending waiters. Incoming calls are unchanged.

The winning result proceeds through the existing owner join, Android `media_prepared` or answer acknowledgement, CallKit activation and microphone permission gates. Android still captures and injects carrier audio only after Telecom ACTIVE. This change advances transport negotiation; it does not relay actual carrier ringback or promise that every call has audio before answer. No Relay runtime change is needed; its tests verify that the acceptance status reaches an unowned iPhone without claiming ownership or allowing WebRTC signaling.

One Android 85 device trace showed an Agent socket connected at 10:58:43.106, Telecom ACTIVE at 10:58:45.151, and WebRTC startup at 10:58:45.185. ICE configuration was already prefetched and took 4 ms. The carrier uplink subsequently logged a 1,012 ms silence interval, and the first stats sample reported 92 dropped 10 ms capture frames. Those counters concern opposite directions and are not a direct measurement of lost speech at the iPhone. The trace proves late negotiation on that call, but cannot separate HTTP polling, iPhone socket/ping, owner admission or an older iPhone installation. The physical iPhone was unavailable for version and log inspection. Unit and simulator tests cannot establish the timing improvement; compare the new phase timestamps on a user-initiated call.

## Relay response and admission latency

The dial HTTP response contains the call identity the iPhone needs to begin silent preparation. After the command has been durably stored and accepted for delivery, best-effort dashboard telemetry must not hold that response. The Worker retains that telemetry with its execution context's `waitUntil`; environments without an execution context retain the awaited behavior. Authentication, admission checks, call/command persistence and dispatch are still awaited. This changes diagnostic scheduling, not permission to dial or acquire audio.

Owner admission reads the device record and latest heartbeat together from the authoritative STATUS registry. A complete fresh snapshot avoids two sequential RPCs to that same registry without caching readiness or changing its expiry. Missing or invalid authoritative data fails closed. The exceptional legacy device-mirror path must still read the latest authoritative heartbeat after the mirror read completes, so revocation during that read cannot be hidden. Ownership, cancellation and current-call checks remain in place after admission awaits. This optimization requires a Relay deployment; it changes no public signaling schema or durable-storage migration.

Retained Android 87 app markers showed 1.31 s and 1.69 s from successful dial invocation to owner join, while prefetched ICE took only 3 ms and 2 ms. These timestamps isolate a remaining interval but do not attribute all of it to Relay storage, iPhone audio-session work or an unverified installed iPhone version. Deferred-persistence tests can establish that diagnostics no longer block the response, and RPC-count tests can establish the removed round trip. Actual connection-time improvement still needs a new authorized call measurement.

## Standalone answer confirmation and recording

The standalone Android agent sends `answer_ok` after Telecom confirms an incoming call is active, or an outgoing owner joins an already active call. For an outgoing call still dialing, it sends `media_prepared` and starts a native peer without the carrier device. When Telecom becomes active, `activate_audio` opens the carrier route on that same peer and `active` updates the iPhone lifecycle. Preparation alone does not start the call timer or enable recording. Reconnect requires a fresh `answer_ok` or outgoing `media_prepared`; queued/forwarded commands and WebRTC readiness alone cannot mark a cellular call connected. The lifecycle merger rejects late confirmation after hangup.

## Initial connection and retries

The first Cloud Relay audio negotiation displays **Connecting Cloud Audio**. **Retrying Cloud Audio N/M** is reserved for recovery after a disconnect/failure or replacement of an existing peer; the initial peer connection must not be presented as retry 1. This display distinction does not remove the required CallKit, answer acknowledgement, ICE or carrier-route gates.

The iPhone trace recorder logs `setup_started`, `signaling_connected`, `media_prepared` or `answer_confirmed`, `ice_prepared`, `peer_started`, `native_connected`, `carrier_ready` and `audio_ready`, with monotonic `setup_elapsed_ms` from the beginning of that call. `ice_wait_ms` measures the wait for the per-call ICE preparation result. Comparing outgoing `native_connected` against the `active` control event confirms whether negotiation finished during ringback. These phase timings would distinguish slow setup from a real rebuild without logging SDP, ICE credentials or audio, but the app currently has no way to turn this trace on or read it; see [Diagnostics](#diagnostics). Actual elapsed latency requires a device call; a passing simulator test does not establish it.

Control-message handling does not await file-backed trace persistence. Answer confirmation and media-readiness updates proceed independently of diagnostic disk writes.

## Incoming activation ordering

CallKit audio activation and cloud signaling preparation may finish in either order during a cold launch. Both callbacks now arm startup for a user-accepted, prepared call while Android answer confirmation is pending. Peer creation still waits for `answer_ok` (or valid `active`) and the active CallKit audio session. Previously the cold-launch handler checked for an already-active call only during `didActivate`, so an earlier activation could leave audio startup unarmed even after Android confirmed the answer.

This fixes the callback ordering; it does not claim physical call latency or eliminate Android's post-ACTIVE carrier attachment. Carrier ringback audio is still not captured before ACTIVE.

## Android credential preparation

As soon as the call's Agent signaling socket connects, Android starts a call-scoped ICE/TURN credential request. This overlaps ringing and answer confirmation. Prefetch does not invoke the privileged media service or capture/inject carrier audio. The outgoing owner can start its native peer during dialing; carrier capture/injection still waits for Telecom's active state.

Answer startup joins the same in-flight request or reuses its still-valid result. The lease starts at request time, with a safety margin; expired or missing-TTL preparation is fetched again. A failed speculative request is retried through normal startup and does not fail an unanswered call. Closing or replacing the call cancels preparation and cannot start native audio afterward. Credentials remain in the ordinary app and are never included in logs.

The Android event `webrtc_ice_ready` reports `prefetched` and `wait_ms`. A ready prefetch removes credential-fetch waiting from the post-answer path. This does not remove ICE connectivity checks, native initialization, carrier routing, or the need for physical latency measurement.

## Bounded native signaling bursts

The app previously requested and forwarded only one native SDP/ICE/status event per 40 ms poll. An already-queued burst therefore accumulated an extra 40 ms between every event, even though its native work had finished. The app now drains at most eight events in one worker turn and checks an 8 ms time budget between operations. It stops immediately on an empty queue, terminal failure or close. The unchanged 40 ms interval still applies between turns, so idle polling is not faster, and queued activation/stop work is not starved by an unbounded drain. A single IPC/network operation can itself exceed the budget; it is not forcibly interrupted.

Each event still uses its own bounded IPC response with the existing request ID, owner and call identity checks. SDP and ICE are not combined into an oversized message. Native event order and the carrier-activation gates are unchanged. A deterministic model of twelve already-ready events with zero transport cost delivers the last event after 40 ms instead of 440 ms of polling gaps. This measures removed scheduling delay in that fixture, not a real call's setup improvement.

## Carrier attach and setup recovery

Android attaches carrier audio as soon as `AirSIMInCallService` sees Telecom ACTIVE, instead of waiting for the 2-second agent loop and its Relay HTTP work. The loop still publishes the lifecycle; `active` is sent to the owner once per media socket.

Route verification uses nonblocking silence priming with its existing 2-second deadline; initial downlink capture has a separate 2-second deadline. Partial progress does not restart either budget, and cancellation stops both loops. This prevents a blocked startup write or first read from silently bypassing recovery. It does not relax TYPE_TELEPHONY verification or move carrier audio before ACTIVE.

If the carrier device fails before its TELEPHONY route is first verified, the native peer releases that device and attaches a new one to the same peer: up to 4 attempts, 300 ms apart. ICE/DTLS and the call socket stay up, so the iPhone does not renegotiate. The first verification is unchanged: the routed device must be the TELEPHONY sink. Each failure has a non-sensitive reason code (for example `carrier_route_unverified`, `ice_failed`, `sdp_set_failed`, `owner_lease_expired`). The app logs it as `privileged_webrtc_unavailable reason=…` and sends the owner a diagnostic `agent_media_failed` status before rebuilding its media socket. The iPhone keeps that status only in its trace.

After that verification, the uplink checks the routed device before every write, and a failure ends the peer:

- `carrier_route_changed_type_N`: the platform reports a device that is not the TELEPHONY sink. `N` is the Android `AudioDeviceInfo` type, for example 1 for the earpiece and 2 for the speaker. This fails at once and nothing is written to that device.
- `carrier_route_inactive`: the platform reports no routed device for 300 ms while audio is being written. Only a write restarts an AudioTrack that Android deactivated, and audio policy applies its route again a moment later, so a missing device is not fatal on first sight. During those 300 ms the uplink writes without waiting on the track. No other device is accepted and the preferred device stays the TELEPHONY sink.

Both replace the earlier `carrier_route_lost`, which did not tell them apart and ended the peer on the first missing report.

The carrier device can attach before WebRTC playout exists: the call is already active when the owner's `answer` arrives, or the media socket is rebuilt during an active call. Until the offer is answered there is no decoded audio, so the uplink writes silence to keep the carrier AudioTrack active and routed; see [Latency and stability diagnostics](webrtc.md#latency-and-stability-diagnostics). Each such gap is logged by the privileged process as `standalone_carrier_silence_started skipped=…` and `standalone_carrier_silence_stopped gap_ms=… frames=…`. At most one gap per second is logged; `skipped` counts the gaps left out since the previous line. A short gap at attach is normal. A `started` line with no `stopped` line before `standalone_webrtc_failed` means the peer ended during the gap.

When an answer arrives while the previous native peer is still releasing resources, Android waits up to 3 seconds for the privileged service instead of replying `action_error`. A heartbeat that reported media unavailable is refreshed on the next 2-second agent cycle once the service is ready again, rather than up to 30 seconds later.

The iPhone resends `answer` after 1 second on `answer_pending`, `action_error` or `action_rejected`. This happens only inside the existing confirmation window, so the overall budget and its final failure state are unchanged. Relay `webrtc_failed` rejections without a session id that read `peer unavailable…` or `stale signaling session` no longer rebuild the iPhone socket; the Relay's `peer_connected` for the agent already triggers renegotiation. A native ICE disconnect before audio was ever ready is traced as `native_disconnected` and is not presented as **Retrying Cloud Audio**. CallKit audio activation no longer waits for its trace write.

These are source changes validated by JVM and simulator tests. Carrier-route timing on Pixel 8 Pro and Q25, and end-to-end setup latency, still require physical calls.

## Diagnostics

The iPhone trace recorder (`AgentVerboseTraceRecorder`) writes events only when the `agent_verbose_trace_enabled` user default is on. The trace screens and their on/off switch were removed, so nothing in the app turns it on and nothing displays or exports it. Entries are kept only in the app's Application Support container. This covers the detailed recorder events, including `ice_prepared`, `native_connected`, `native_disconnected`, `agent_media_failed` and `webrtc_stats`.

The separate outgoing setup timeline is always written to the unified log under subsystem `com.example.airsim.call-setup`, category `outgoing`. It records a per-launch dial counter, fixed phase names, monotonic milliseconds and fixed details, without phone numbers, call identifiers, credentials, SDP or audio. Inspect it with Console for the connected iPhone or an authorized device log collection. `dial_acceptance` includes `source=signaling` or `source=http`; `signaling_adoption_started`, `prewarm_signaling_connected` and `signaling_connected` separate acceptance from socket adoption. The prewarm connection can complete through pong or verified acceptance. `owner_join_sent` records the socket-send invocation time rather than later main-thread delivery; it is not proof of server receipt. `media_prepared`, `peer_started`, `native_connected`, `active` and `audio_ready` cover the later stages. Do not treat the Android socket timestamp as proof that the iPhone socket connected at the same time.

Android logs to logcat under the tag `AirSIMBridge`:

- The app process logs `standalone_cloud_media_connected`, `webrtc_ice_ready prefetched=… wait_ms=…` and `privileged_webrtc_unavailable reason=…`. With **Enable debug mode** on, the app also keeps these lines in its own debug log, which **Copy logs** and **Export diagnostics** share.
- The privileged Shizuku process logs `standalone_carrier_attach_retry attempt=… reason=…`, `standalone_carrier_silence_started`, `standalone_carrier_silence_stopped gap_ms=… frames=…`, `standalone_webrtc_failed reason=…` and `standalone_webrtc_stats`. These appear only in logcat (`adb logcat -s AirSIMBridge`), not in the in-app debug log.
- `standalone_audio_setup` records fixed phases once per app session, native peer or carrier attempt. Its `scope`, `phase`, `elapsed_ms` and device-monotonic `monotonic_s` distinguish dial acceptance, owner join receipt, deferred/active media start, carrier activation, verified route, first capture, carrier ready and native connection. Different scopes have different elapsed-time origins; compare `monotonic_s` on the same Android device, not against the iPhone clock. These lines contain no call identity or audio.

Logcat and the debug log carry timestamps, but neither records the iPhone-side phases, so they cannot measure the full setup timeline on their own.

## Persistent Android carrier-route failures

Cloud signaling and TURN credential retrieval can succeed while Android has no usable carrier
output route. For example, Android's audio-policy service can retain an output-patch entry that
AudioFlinger no longer has. Rebuilding the WebRTC peer does not reset either system service.
A successful `AudioTrack.write`, advancing playback head, or preferred TELEPHONY device alone
is not proof that audio reaches the carrier. Do not bypass the actual TELEPHONY route check.

A cloud call permits three native-peer failures with known carrier-route reason codes. The
existing bounded carrier-attachment attempts still run within each native peer. After the third
route failure, Android releases media but retains the control socket, sends
`agent_media_failed` with `message: carrier_route_recovery_required`, and stops starting new
peers for that call UUID and generation. Socket reconnection and repeated answer controls replay
the recovery status instead of fetching credentials or reopening carrier audio. Network and ICE
errors retain their existing retry behavior and do not spend the carrier-route budget. A new
call or generation has a fresh budget. No state is written to pairing or persistent device data.

A matching iPhone build displays an Android call-audio recovery message. It stops audio-start
and reconnect tasks without ending the cellular call or disabling end/reject controls. Late
readiness callbacks cannot replace the message with a false connected/retrying state. The
existing Relay forwards this status, so no Relay deployment or protocol migration is needed.
After this terminal media failure, iPhone does not rebuild its signaling connection if that
connection later drops; explicit end/reject still uses the durable HTTP control path.
Older iPhone builds still receive the diagnostic but may continue displaying their older UI.

This change bounds and explains a failure; it does **not** repair an Android system route or
establish that every route failure has the same cause. End the current call before restarting
the Android phone. Reopen AirSIM and restart/reconnect Shizuku if needed. Do not clear app data,
reinstall, manually create/release system audio patches, or accept a speaker route as a fallback.
A reboot is a recovery step, not a proven permanent fix. If the failure returns, collect fresh
route-state evidence before changing routing behavior.

Tests run the real cloud-session loop with fake network/native boundaries and cover a bounded
route-failure budget, ordinary ICE failure, stale peer callbacks, answer replay, ACTIVE/SDP
suppression, control reconnection, explicit end/reject, and a fresh generation. iPhone tests
cover exact token and identity validation, sticky failure state, permitted lifecycle controls,
and reset for a new call. These tests open no hardware route and make no real calls. Physical
acceptance still requires a user-initiated cloud call after recovery, including bidirectional
speech, hangup, repeated calls, and confirmation that the failure does not recur.
