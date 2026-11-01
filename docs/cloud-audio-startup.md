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

If the carrier device fails before its TELEPHONY route is first verified, the native peer releases that device and attaches a new one to the same peer: up to 4 attempts, 300 ms apart. ICE/DTLS and the call socket stay up, so the iPhone does not renegotiate. The route check is unchanged, and a loss after the route was verified still ends the peer. Each failure has a non-sensitive reason code (for example `carrier_route_unverified`, `ice_failed`, `sdp_set_failed`, `owner_lease_expired`). The app logs it as `privileged_webrtc_unavailable reason=…` and sends the owner a diagnostic `agent_media_failed` status before rebuilding its media socket. The iPhone keeps that status only in its trace.

When an answer arrives while the previous native peer is still releasing resources, Android waits up to 3 seconds for the privileged service instead of replying `action_error`. A heartbeat that reported media unavailable is refreshed on the next 2-second agent cycle once the service is ready again, rather than up to 30 seconds later.

The iPhone resends `answer` after 1 second on `answer_pending`, `action_error` or `action_rejected`. This happens only inside the existing confirmation window, so the overall budget and its final failure state are unchanged. Relay `webrtc_failed` rejections without a session id that read `peer unavailable…` or `stale signaling session` no longer rebuild the iPhone socket; the Relay's `peer_connected` for the agent already triggers renegotiation. A native ICE disconnect before audio was ever ready is traced as `native_disconnected` and is not presented as **Retrying Cloud Audio**. CallKit audio activation no longer waits for its trace write.

These are source changes validated by JVM and simulator tests. Carrier-route timing on Pixel 8 Pro and Q25, and end-to-end setup latency, still require physical calls.

## Diagnostics

The iPhone trace recorder (`AgentVerboseTraceRecorder`) writes events only when the `agent_verbose_trace_enabled` user default is on. The trace screens and their on/off switch were removed, so nothing in the app turns it on and nothing displays or exports it. Entries are kept only in the app's Application Support container. This covers every iPhone event named in this document, including `ice_prepared`, `native_connected`, `native_disconnected`, `agent_media_failed` and `webrtc_stats`. Until a way to enable and read the trace returns, use the Android logs below.

Android logs to logcat under the tag `AirSIMBridge`:

- The app process logs `standalone_cloud_media_connected`, `webrtc_ice_ready prefetched=… wait_ms=…` and `privileged_webrtc_unavailable reason=…`. With **Enable debug mode** on, the app also keeps these lines in its own debug log, which **Copy logs** and **Export diagnostics** share.
- The privileged Shizuku process logs `standalone_carrier_attach_retry attempt=… reason=…`, `standalone_webrtc_failed reason=…` and `standalone_webrtc_stats`. These appear only in logcat (`adb logcat -s AirSIMBridge`), not in the in-app debug log.

Logcat and the debug log carry timestamps, but neither records the iPhone-side phases, so they cannot measure the full setup timeline on their own.
