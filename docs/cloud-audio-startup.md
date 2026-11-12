# Cloud audio startup on iPhone

> Current branch migration: native WebRTC and carrier capture/injection share the privileged Android process. There is no supported PCM network/IPC fallback. The AVF runtime is retired; Watch is an iPhone audio companion. Legacy bridge source/build instructions below are historical reference, not the current APK workflow. Physical-route and privileged-security gates remain unverified. See [the migration contract](webrtc-only-migration.md).


The iPhone prepares the current call's TURN credentials and shared native WebRTC factory while its control WebSocket connects. Android also prefetches call-scoped credentials. Outgoing calls can then negotiate WebRTC during dialing/ringback, before the remote party answers. This requires matching iOS and Android builds; no Relay protocol deployment is required.

Credential prefetch alone does not create a peer or start audio. Outgoing `media_prepared` acknowledgement permits SDP and ICE after CallKit activation and microphone permission. The Android carrier device stays closed until Telecom reports active. Incoming calls retain successful answer confirmation as their startup gate. Current call identity and native/agent readiness checks still control usable audio. Codec, packet duration, jitter buffering, and playback behavior are unchanged.

TURN requests are shared only within the same call UUID, generation, Relay endpoint, and bearer credential. Hangup cancels preparation and discards credentials. A temporary audio interruption keeps the shared request available for the same call. Expired credentials are refreshed with a safety margin, and a failed prefetch can retry once when needed. Credentials remain in memory and are never included in diagnostics.

The iPhone trace event `ice_prepared` (category `cloud-call-audio`) includes `ice_wait_ms`: time still spent waiting for TURN configuration after the audio-start gates open. Near zero means the configuration was ready or completed immediately; this is not an end-to-end audio latency measurement. Comparing answer acknowledgement and `webrtc_ready` timestamps in the same call measures startup. That trace currently cannot be turned on or read in the app; see [Diagnostics](#diagnostics). Actual reduction requires a new external-network call; simulator tests do not establish carrier-call timing or quality.

Preparation tests cover request coalescing, expiration, transient and repeated failure, hangup, audio interruption, and credential/Relay rotation. Outgoing handshake tests also distinguish peer preparation from cellular answer, require a fresh reconnect acknowledgement, and keep recording unavailable until the call becomes active. Android tests cover deferred carrier activation, owner identity, reuse of the prepared peer, and cancellation before activation.

## Standalone answer confirmation and recording

The standalone Android agent sends `answer_ok` after Telecom confirms an incoming call is active, or an outgoing owner joins an already active call. For an outgoing call still dialing, it sends `media_prepared` and starts a native peer without the carrier device. When Telecom becomes active, `activate_audio` opens the carrier route on that same peer and `active` updates the iPhone lifecycle. Preparation alone does not start the call timer or enable recording. Reconnect requires a fresh `answer_ok` or outgoing `media_prepared`; queued/forwarded commands and WebRTC readiness alone cannot mark a cellular call connected. The lifecycle merger rejects late confirmation after hangup.

## Initial connection and retries

The first Cloud Relay audio negotiation displays **Connecting Cloud Audio**. **Retrying Cloud Audio N/M** is reserved for recovery after a disconnect/failure or replacement of an existing peer; the initial peer connection must not be presented as retry 1. This display distinction does not remove the required CallKit, answer acknowledgement, ICE or carrier-route gates.

The iPhone trace recorder logs `setup_started`, `signaling_connected`, `media_prepared` or `answer_confirmed`, `ice_prepared`, `peer_started`, `native_connected`, `carrier_ready` and `audio_ready`, with monotonic `setup_elapsed_ms` from the beginning of that call. `ice_wait_ms` measures the wait for the per-call ICE preparation result. Comparing outgoing `native_connected` against the `active` control event confirms whether negotiation finished during ringback. These phase timings would distinguish slow setup from a real rebuild without logging SDP, ICE credentials or audio, but the app currently has no way to turn this trace on or read it; see [Diagnostics](#diagnostics). Actual elapsed latency requires a device call; a passing simulator test does not establish it.

Control-message handling does not await file-backed trace persistence. Answer confirmation and media-readiness updates proceed independently of diagnostic disk writes.

## Android credential preparation

As soon as the call's Agent signaling socket connects, Android starts a call-scoped ICE/TURN credential request. This overlaps ringing and answer confirmation. Prefetch does not invoke the privileged media service or capture/inject carrier audio. The outgoing owner can start its native peer during dialing; carrier capture/injection still waits for Telecom's active state.

Answer startup joins the same in-flight request or reuses its still-valid result. The lease starts at request time, with a safety margin; expired or missing-TTL preparation is fetched again. A failed speculative request is retried through normal startup and does not fail an unanswered call. Closing or replacing the call cancels preparation and cannot start native audio afterward. Credentials remain in the ordinary app and are never included in logs.

The Android event `webrtc_ice_ready` reports `prefetched` and `wait_ms`. A ready prefetch removes credential-fetch waiting from the post-answer path. This does not remove ICE connectivity checks, native initialization, carrier routing, or the need for physical latency measurement.

## Carrier attach and setup recovery

Android attaches carrier audio as soon as `AirSIMInCallService` sees Telecom ACTIVE, instead of waiting for the 2-second agent loop and its Relay HTTP work. The loop still publishes the lifecycle; `active` is sent to the owner once per media socket.

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

The iPhone trace recorder (`AgentVerboseTraceRecorder`) writes events only when the `agent_verbose_trace_enabled` user default is on. The trace screens and their on/off switch were removed, so nothing in the app turns it on and nothing displays or exports it. Entries are kept only in the app's Application Support container. This covers every iPhone event named in this document, including `ice_prepared`, `native_connected`, `native_disconnected`, `agent_media_failed` and `webrtc_stats`. Until a way to enable and read the trace returns, use the Android logs below.

Android logs to logcat under the tag `AirSIMBridge`:

- The app process logs `standalone_cloud_media_connected`, `webrtc_ice_ready prefetched=… wait_ms=…` and `privileged_webrtc_unavailable reason=…`. With **Enable debug mode** on, the app also keeps these lines in its own debug log, which **Copy logs** and **Export diagnostics** share.
- The privileged Shizuku process logs `standalone_carrier_attach_retry attempt=… reason=…`, `standalone_carrier_silence_started`, `standalone_carrier_silence_stopped gap_ms=… frames=…`, `standalone_webrtc_failed reason=…` and `standalone_webrtc_stats`. These appear only in logcat (`adb logcat -s AirSIMBridge`), not in the in-app debug log.

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
