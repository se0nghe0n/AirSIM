# Cloud audio startup on iPhone

> Current branch migration: native WebRTC and carrier capture/injection share the privileged Android process. There is no supported PCM network/IPC fallback. The AVF runtime is retired; Watch is an iPhone audio companion. Legacy bridge source/build instructions below are historical reference, not the current APK workflow. Physical-route and privileged-security gates remain unverified. See [the migration contract](webrtc-only-migration.md).


The iPhone prepares the current call's TURN credentials and shared native WebRTC factory while its control WebSocket connects and the Android agent confirms the answer. This removes those preparation steps from the serial path after answer acknowledgement. No Android update or Relay protocol change is required.

Preparation does not create a peer, send SDP, or start recording/playback. The existing answer acknowledgement, current call identity, CallKit activation, microphone permission, and native/agent readiness checks still control audio startup. Codec, packet duration, jitter buffering, and playback behavior are unchanged.

TURN requests are shared only within the same call UUID, generation, Relay endpoint, and bearer credential. Hangup cancels preparation and discards credentials. A temporary audio interruption keeps the shared request available for the same call. Expired credentials are refreshed with a safety margin, and a failed prefetch can retry once when needed. Credentials remain in memory and are never included in diagnostics.

The `cloud-call-audio` event `ice_prepared` includes `ice_wait_ms`: time still spent waiting for TURN configuration after the audio-start gates open. Near zero means the configuration was ready or completed immediately; this is not an end-to-end audio latency measurement. Compare answer acknowledgement and `webrtc_ready` timestamps in the same call to measure startup. Actual reduction requires a new external-network call; simulator tests do not establish carrier-call timing or quality.

Validation: seven preparation tests cover request coalescing, expiration, transient and repeated failure, hangup, audio interruption, and credential/Relay rotation. Existing WebRTC handshake, readiness, host-ICE negotiation, and recording tests remain applicable. Android-side setup and cellular confirmation delays require separate future work on the Android agent.

## Standalone answer confirmation and recording

The standalone Android agent sends `answer_ok` after Telecom confirms the cellular call is active. Its WebRTC path does not send the legacy PCM bridge's later `active` event. iPhone therefore publishes the active call lifecycle when the answer handshake accepts `answer_ok`, before starting media. Recording availability observes that lifecycle, rather than a separate displayed record. Reconnect still requires a fresh answer acknowledgement; queued/forwarded commands and WebRTC readiness alone cannot mark a cellular call connected. The lifecycle merger rejects late confirmation after hangup.

## Initial connection and retries

The first Cloud Relay audio negotiation displays **Connecting Cloud Audio**. **Retrying Cloud Audio N/M** is reserved for recovery after a disconnect/failure or replacement of an existing peer; the initial peer connection must not be presented as retry 1. This display distinction does not remove the required CallKit, answer acknowledgement, ICE or carrier-route gates.

The existing private diagnostic trace now records `setup_started`, `signaling_connected`, `answer_confirmed`, `ice_prepared`, `peer_started`, `native_connected`, `carrier_ready` and `audio_ready`, with monotonic `setup_elapsed_ms` from the beginning of that call. `ice_wait_ms` measures the wait for the per-call ICE preparation result. These phase timings help distinguish slow setup from a real rebuild without logging SDP, ICE credentials or audio. Actual elapsed latency requires a device call trace; a passing simulator test does not establish it.

Control-message handling does not await file-backed trace persistence. Answer confirmation and media-readiness updates proceed independently of diagnostic disk writes.

## Android credential preparation

As soon as the call's Agent signaling socket connects, Android starts a call-scoped ICE/TURN credential request. This overlaps ringing and answer confirmation. Preparation does not invoke the privileged media service, start a native peer, or capture/inject carrier audio. Those operations still start only after Telecom confirms the answer.

Answer startup joins the same in-flight request or reuses its still-valid result. The lease starts at request time, with a safety margin; expired or missing-TTL preparation is fetched again. A failed speculative request is retried through normal startup and does not fail an unanswered call. Closing or replacing the call cancels preparation and cannot start native audio afterward. Credentials remain in the ordinary app and are never included in logs.

The Android event `webrtc_ice_ready` reports `prefetched` and `wait_ms`. A ready prefetch removes credential-fetch waiting from the post-answer path. This does not remove ICE connectivity checks, native initialization, carrier routing, or the need for physical latency measurement.
