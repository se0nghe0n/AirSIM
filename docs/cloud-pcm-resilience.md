# Cloud PCM Reliability and Latency

This change preserves the existing Relay WebSocket, authentication, CallKit/PushKit, and raw PCM protocols. It does not change media implementations for VoWLAN, VoBLE, or the legacy Linux Agent.

## Finalizing hang-up

After the iPhone submits `ending`, it immediately closes the call presentation, ringtone, and Watch call indication while continuing to await Agent/baseband confirmation of the existing persistent hang-up command. Closing the UI does not prove the remote call has ended; a final failure still displays an error.

The lifecycle reducer retains up to 64 ended identities and rejects late `ringing/connecting/active` events for the same call, including callbacks with a higher generation. Polling cannot bypass the reducer to recreate a CallKit call. Cloud media callbacks are bound to their WebSocket connection identity and checked again after asynchronous logging; old call acknowledgments cannot modify new call media state. After awaiting a cloud-status query, Dynamic Island rereads the current lifecycle instead of using the pre-query snapshot.

## Audio strategy

- Both ends use 20 ms/320-byte, 8 kHz, 16-bit mono PCM, retaining protocol compatibility without new codec dependencies.
- Both receivers initially prebuffer 4 frames (80 ms). The standalone Android receiver grows to 10 frames (200 ms) and caps its queue at 12 frames (240 ms). The iPhone receiver reserves up to 60 frames (1,200 ms) after observed delivery stalls and caps its queue at 90 frames (1,800 ms), with at most 2 additional frames (40 ms) in the player. These are local queue bounds, not an end-to-end latency guarantee.
- After 100 stable arrivals, the iPhone lowers its next rebuffer target by one frame. It does not discard queued speech when that target decreases. The larger reserve preserves ordered audio delivered in a burst after a temporary transport stall.
- Brief gaps receive at most 2 frames of attenuated audio concealment (40 ms), with 5 ms boundary smoothing on recovery. Longer gaps rebuffer instead of repeating old audio indefinitely. This is simple PCM gap concealment, not full NetEq, Opus PLC, or FEC.
- Senders queue at most 12 frames and drop pending speech older than 250 ms. They send one frame at a time and do not burst to catch up after a stall.
- Android separates PCM capture, network send, network receive, and PCM playback. Network audio writes do not occupy the control-frame reader. An audio write blocked for more than 2 seconds closes its own connection so existing reconnection logic can recover; an old worker cannot close a new connection.
- Rebuilding an Android WebSocket resets media startup state, allowing a repeated iPhone `answer` to restart PCM.
- Queue size, target buffer, dropped frames, missing frames, and concealed frames are logged every 5 seconds; PCM content is not logged.

## Latency recovery

The iPhone attempts a paced send as soon as a complete microphone frame is ready. The standalone Android sender wakes when capture queues a complete frame, and keeps a minimum 20 ms interval between network send starts. Both retain one network writer, bounded queues and stale-frame expiry. This removes an avoidable wait for the next sender tick, up to about 20 ms in each direction; it is not a measured end-to-end saving.

The iPhone also shortens **digital silence only** when buffered audio exceeds the learned reserve. It keeps the leading and trailing parts of a contiguous run of at least five all-zero PCM frames, removes at most one interior frame per five real scheduled frames, and retains the full current target after filling the player. Even a single nonzero sample disqualifies a frame. This preserves quiet speech and comfort noise instead of trying to classify them as silence. Intentional silence shortening is reported separately from loss, and is disabled across missing sequences and concealment recovery.

The initial 80 ms reserve, long-stall protection, playback rate and pitch remain unchanged. Continuous speech or nonzero background noise does not become shorter. A large learned reserve also remains until its existing stable-arrival decay lowers it. This first change therefore recovers excess queue latency opportunistically; it does not promise a low-latency call over a link that repeatedly stalls for a second.

Quality logs distinguish these local measurements:

- `rx_app_buffer_ms`: queued PCM duration plus player reservations, estimated as frame count times 20 ms.
- `rx_render_age_ms` / `rx_render_age_max_ms`: latest and per-call maximum residence from the iPhone receive callback to the player render completion, using the same monotonic clock. Concealed frames are excluded. This excludes audio-device presentation and upstream transport latency.
- `audio_input_latency_ms`, `audio_output_latency_ms`, `audio_io_buffer_ms`: the active audio session's reported hardware/pipeline values; they must not be added indiscriminately to the render metric.
- `rx_silence_compacted`: cumulative number of deliberately shortened 20 ms digital-silence frames. `rx_drop` continues to report actual loss separately.

## References and limitations

The design draws on [WebRTC NetEq adaptive buffering and playout timing](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_coding/neteq/g3doc/index.md) and the [Telegram libtgvoip jitter buffer](https://github.com/telegramdesktop/libtgvoip/blob/master/JitterBuffer.cpp). It independently implements a simplified strategy for the existing PCM path without copying their implementation or adding their dependencies.

The transport remains WebSocket/TCP. Local buffering cannot eliminate TCP retransmission, head-of-line blocking, or queues inside the OS and Relay. The optional ASPM v2 envelope carries source and Relay timing plus a wire sequence number. These diagnose missing envelopes and changes in delivery cadence; unsynchronized device clocks still prevent exact one-way network-delay measurement. The jitter buffer uses separate local arrival ordinals, which do not establish network packet-loss rates. Severe network impairment can still interrupt audio. Moving to WebRTC/Opus, SRTP/UDP, and TURN is a separate coordinated client/server project outside this change.

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


## Fork validation: 2026-10-17

All 138 iOS unit tests passed on the iOS 18.6 simulator. The 14 buffer/latency tests also ran directly on the macOS host using the same extracted production buffer and test methods. The standalone Android JVM suite and debug APK build/signature checks passed. New iOS 27/27.1 simulators failed initial data migration before test execution; the existing simulator was used instead.

An offline comparison against commit `ea57e94` used synthetic packet arrivals, not a recording of every production packet. With an initial 20-frame backlog followed by digital silence and normal arrivals, the final speech segment's source-to-render delay fell from 400 ms to 120 ms by shortening 14 silent frames. All nonzero frames survived in order, with zero loss and zero underruns. The steady speech case remained at 80 ms. Repeated 600/850/1,052 ms stalls retained identical protection and latency in both versions; this change does not claim to shorten the required reserve on those impaired paths.

No phone installation, production Relay deployment, or new live-call measurement was performed for this change. Simulator and replay results do not establish perceptual quality or real end-to-end latency.
