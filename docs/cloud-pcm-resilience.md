# Cloud Hang-up and PCM Jitter Mitigation (v0.9.7.1)

This change preserves the existing Relay WebSocket, authentication, CallKit/PushKit, and raw PCM protocols. It does not change media implementations for VoWLAN, VoBLE, or the legacy Linux Agent.

## Finalizing hang-up

After the iPhone submits `ending`, it immediately closes the call presentation, ringtone, and Watch call indication while continuing to await Agent/baseband confirmation of the existing persistent hang-up command. Closing the UI does not prove the remote call has ended; a final failure still displays an error.

The lifecycle reducer retains up to 64 ended identities and rejects late `ringing/connecting/active` events for the same call, including callbacks with a higher generation. Polling cannot bypass the reducer to recreate a CallKit call. Cloud media callbacks are bound to their WebSocket connection identity and checked again after asynchronous logging; old call acknowledgments cannot modify new call media state. After awaiting a cloud-status query, Dynamic Island rereads the current lifecycle instead of using the pre-query snapshot.

## Audio strategy

- Both ends use 20 ms/320-byte, 8 kHz, 16-bit mono PCM, retaining protocol compatibility without new codec dependencies.
- Receivers initially prebuffer 4 frames (80 ms), increasing with arrival jitter and missing frames to a target of at most 10 frames (200 ms). After 100 stable arrivals, the target gradually decreases.
- The receive queue has a hard limit of 12 frames (240 ms); the iPhone player schedules at most 2 additional frames (40 ms). These are application queue limits, not an end-to-end latency guarantee.
- Brief gaps receive at most 2 frames of attenuated audio concealment (40 ms), with 5 ms boundary smoothing on recovery. Longer gaps rebuffer instead of repeating old audio indefinitely. This is simple PCM gap concealment, not full NetEq, Opus PLC, or FEC.
- Senders queue at most 12 frames and drop pending speech older than 250 ms. They send one frame at a time and do not burst to catch up after a stall.
- Android separates PCM capture, network send, network receive, and PCM playback. Network audio writes do not occupy the control-frame reader. An audio write blocked for more than 2 seconds closes its own connection so existing reconnection logic can recover; an old worker cannot close a new connection.
- Rebuilding an Android WebSocket resets media startup state, allowing a repeated iPhone `answer` to restart PCM.
- Queue size, target buffer, dropped frames, missing frames, and concealed frames are logged every 5 seconds; PCM content is not logged.

## References and limitations

The design draws on [WebRTC NetEq adaptive buffering and playout timing](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md) and the [Telegram libtgvoip jitter buffer](https://github.com/telegramdesktop/libtgvoip/blob/master/JitterBuffer.cpp). It independently implements a simplified strategy for the existing PCM path without copying their implementation or adding their dependencies.

The transport remains WebSocket/TCP. Local buffering cannot eliminate TCP retransmission, head-of-line blocking, or queues inside the OS and Relay. Raw PCM has no source sequence numbers or timestamps; iPhone sequence numbers represent local arrival order and cannot establish network packet-loss rates or complete end-to-end latency. Severe network impairment can still interrupt audio. Moving to WebRTC/Opus, SRTP/UDP, and TURN is a separate coordinated client/server project outside this change.

## Validation

Automated coverage includes late states after hang-up, higher generations, old events after a subsequent call ends, callback identity, send backlog/expiry, receive burst limits, buffer reduction, brief concealment, playback windows, and synthetic PCM showing that a blocked network sender does not block receive playback. The targeted Android legacy-API scan runs with the build.

Device acceptance must use Release builds with matching signatures and a sandbox Relay, installed over the existing app without clearing data. Simulated tests do not establish real listening quality.

1. Hang up after a cloud outgoing or incoming call; observe for 30 seconds and confirm the call UI, Watch, and Dynamic Island do not restore the old call.
2. Start another call immediately after hang-up; old acknowledgments must neither end nor activate it.
3. Speak in both directions and introduce brief network jitter. Check audio, buffer-target reduction, and drop classifications without saving or uploading voice.
4. Interrupt and restore the network, then confirm another `answer` restarts PCM. Seamless recovery after a long outage is not guaranteed.
5. Retest VoWLAN and VoBLE to confirm the cloud buffering path does not take over.

This document does not establish that a device issue is fixed before actual-call acceptance is complete. Release and deployment require separate user authorization; this app release does not deploy the Relay.

Recorded local validation on 2026-10-14: 110 iOS tests passed. Android Standalone tests, synthetic PCM blocking/timeout tests, the targeted legacy Java API scan, and `NewApi` lint passed (this does not mean all historical lint warnings are resolved). Release builds were installed without clearing data on iPhone Air, main AirSIM `0.9.7 (81)` with sandbox/development push signing, and Redmi Standalone `0.9.7.1 (81)`; both launched. The user made cloud calls in that round and reported that the UI no longer reappeared and audio was steadier. This is a recorded manual result, not proof of the complete cause or coverage of every poor-network or carrier condition. The user subsequently authorized committing, pushing, and publishing Apps v0.9.7.1. The production TestFlight build was uploaded separately through Xcode; sandbox testing does not establish production push acceptance.
