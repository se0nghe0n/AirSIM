# Cloud audio startup on iPhone

> Current branch migration: native WebRTC and carrier capture/injection share the privileged Android process. There is no supported PCM network/IPC fallback. AVF voice is upgrade-required; Watch is an iPhone audio companion. Legacy bridge source/build instructions below are historical reference, not the current APK workflow. Physical-route and privileged-security gates remain unverified. See [the migration contract](webrtc-only-migration.md).


The iPhone prepares the current call's TURN credentials and shared native WebRTC factory while its control WebSocket connects and the Android agent confirms the answer. This removes those preparation steps from the serial path after answer acknowledgement. No Android update or Relay protocol change is required.

Preparation does not create a peer, send SDP, or start recording/playback. The existing answer acknowledgement, current call identity, CallKit activation, microphone permission, and native/agent readiness checks still control audio startup. Codec, packet duration, jitter buffering, and playback behavior are unchanged.

TURN requests are shared only within the same call UUID, generation, Relay endpoint, and bearer credential. Hangup cancels preparation and discards credentials. A temporary audio interruption keeps the shared request available for the same call. Expired credentials are refreshed with a safety margin, and a failed prefetch can retry once when needed. Credentials remain in memory and are never included in diagnostics.

The `cloud-call-audio` event `ice_prepared` includes `ice_wait_ms`: time still spent waiting for TURN configuration after the audio-start gates open. Near zero means the configuration was ready or completed immediately; this is not an end-to-end audio latency measurement. Compare answer acknowledgement and `webrtc_ready` timestamps in the same call to measure startup. Actual reduction requires a new external-network call; simulator tests do not establish carrier-call timing or quality.

Validation: seven preparation tests cover request coalescing, expiration, transient and repeated failure, hangup, audio interruption, and credential/Relay rotation. Existing WebRTC handshake, readiness, host-ICE negotiation, and recording tests remain applicable. Android-side setup and cellular confirmation delays require separate future work on the Android agent.

## Standalone answer confirmation and recording

The standalone Android agent sends `answer_ok` after Telecom confirms the cellular call is active. Its WebRTC path does not send the legacy PCM bridge's later `active` event. iPhone therefore publishes the active call lifecycle when the answer handshake accepts `answer_ok`, before starting media. Recording availability observes that lifecycle, rather than a separate displayed record. Reconnect still requires a fresh answer acknowledgement; queued/forwarded commands and WebRTC readiness alone cannot mark a cellular call connected. The lifecycle merger rejects late confirmation after hangup.
